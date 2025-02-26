// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { AggregatorV3Interface } from "../vendor/chainlink/AggregatorV3Interface.sol";
import { IPaymentHelper } from "../interfaces/IPaymentHelper.sol";
import { ISuperRBAC } from "../interfaces/ISuperRBAC.sol";
import { ISuperRegistry } from "../interfaces/ISuperRegistry.sol";
import { IBaseStateRegistry } from "../interfaces/IBaseStateRegistry.sol";
import { IAmbImplementation } from "../interfaces/IAmbImplementation.sol";
import { Error } from "../libraries/Error.sol";
import { DataLib } from "../libraries/DataLib.sol";
import { ProofLib } from "../libraries/ProofLib.sol";
import { ArrayCastLib } from "../libraries/ArrayCastLib.sol";
import "../types/DataTypes.sol";

/// @dev interface to read public variable from state registry
interface ReadOnlyBaseRegistry is IBaseStateRegistry {
    function payloadsCount() external view returns (uint256);
}

/// @title PaymentHelper
/// @author ZeroPoint Labs
/// @dev helps estimating the cost for the entire transaction lifecycle
contract PaymentHelper is IPaymentHelper {
    using DataLib for uint256;
    using ArrayCastLib for LiqRequest;
    using ArrayCastLib for bool;
    using ProofLib for bytes;
    using ProofLib for AMBMessage;

    //////////////////////////////////////////////////////////////
    //                         CONSTANTS                        //
    //////////////////////////////////////////////////////////////

    ISuperRegistry public immutable superRegistry;
    uint64 public immutable CHAIN_ID;
    uint32 private constant TIMELOCK_FORM_ID = 2;

    //////////////////////////////////////////////////////////////
    //                     STATE VARIABLES                      //
    //////////////////////////////////////////////////////////////

    /// @dev xchain params
    mapping(uint64 chainId => AggregatorV3Interface) public nativeFeedOracle;
    mapping(uint64 chainId => AggregatorV3Interface) public gasPriceOracle;
    mapping(uint64 chainId => uint256 gasForSwap) public swapGasUsed;
    mapping(uint64 chainId => uint256 gasForUpdate) public updateGasUsed;
    mapping(uint64 chainId => uint256 gasForOps) public depositGasUsed;
    mapping(uint64 chainId => uint256 gasForOps) public withdrawGasUsed;
    mapping(uint64 chainId => uint256 defaultNativePrice) public nativePrice;
    mapping(uint64 chainId => uint256 defaultGasPrice) public gasPrice;
    mapping(uint64 chainId => uint256 gasPerByte) public gasPerByte;
    mapping(uint64 chainId => uint256 gasForOps) public ackGasCost;
    mapping(uint64 chainId => uint256 gasForOps) public timelockCost;

    /// @dev register transmuter params
    uint256 public totalTransmuterFees;
    bytes public extraDataForTransmuter;

    //////////////////////////////////////////////////////////////
    //                           STRUCTS                        //
    //////////////////////////////////////////////////////////////

    struct EstimateAckCostVars {
        uint256 currPayloadId;
        uint256 payloadHeader;
        uint8 callbackType;
        bytes payloadBody;
        uint8[] ackAmbIds;
        uint8 isMulti;
        uint64 srcChainId;
        bytes message;
    }

    //////////////////////////////////////////////////////////////
    //                       MODIFIERS                          //
    //////////////////////////////////////////////////////////////

    modifier onlyProtocolAdmin() {
        if (!ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasProtocolAdminRole(msg.sender)) {
            revert Error.NOT_PROTOCOL_ADMIN();
        }
        _;
    }

    modifier onlyEmergencyAdmin() {
        if (!ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasEmergencyAdminRole(msg.sender)) {
            revert Error.NOT_EMERGENCY_ADMIN();
        }
        _;
    }

    //////////////////////////////////////////////////////////////
    //                      CONSTRUCTOR                         //
    //////////////////////////////////////////////////////////////

    constructor(address superRegistry_) {
        if (block.chainid > type(uint64).max) {
            revert Error.BLOCK_CHAIN_ID_OUT_OF_BOUNDS();
        }

        CHAIN_ID = uint64(block.chainid);
        superRegistry = ISuperRegistry(superRegistry_);
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL VIEW FUNCTIONS                     //
    //////////////////////////////////////////////////////////////

    /// @inheritdoc IPaymentHelper
    function calculateAMBData(
        uint64 dstChainId_,
        uint8[] calldata ambIds_,
        bytes memory message_
    )
        external
        view
        override
        returns (uint256 totalFees, bytes memory extraData)
    {
        (uint256[] memory gasPerAMB, bytes[] memory extraDataPerAMB, uint256 fees) =
            _estimateAMBFeesReturnExtraData(dstChainId_, ambIds_, message_);

        extraData = abi.encode(AMBExtraData(gasPerAMB, extraDataPerAMB));
        totalFees = fees;
    }

    /// @inheritdoc IPaymentHelper
    function getRegisterTransmuterAMBData()
        external
        view
        override
        returns (uint256 totalFees, bytes memory extraData)
    {
        return (totalTransmuterFees, extraDataForTransmuter);
    }

    /// @inheritdoc IPaymentHelper
    function estimateMultiDstMultiVault(
        MultiDstMultiVaultStateReq calldata req_,
        bool isDeposit_
    )
        external
        view
        override
        returns (uint256 liqAmount, uint256 srcAmount, uint256 dstAmount, uint256 totalAmount)
    {
        uint256 len = req_.dstChainIds.length;
        uint256 superformIdsLen;
        uint256 totalDstGas;

        for (uint256 i; i < len; ++i) {
            totalDstGas = 0;

            /// @dev step 1: estimate amb costs
            uint256 ambFees = _estimateAMBFees(
                req_.ambIds[i], req_.dstChainIds[i], _generateMultiVaultMessage(req_.superformsData[i])
            );

            superformIdsLen = req_.superformsData[i].superformIds.length;

            srcAmount += ambFees;

            if (isDeposit_) {
                /// @dev step 2: estimate update cost (only for deposit)
                totalDstGas += _estimateUpdateCost(req_.dstChainIds[i], superformIdsLen);

                /// @dev step 3: estimation processing cost of acknowledgement
                /// @notice optimistically estimating. (Ideal case scenario: no failed deposits / withdrawals)
                srcAmount += _estimateAckProcessingCost(superformIdsLen);

                /// @dev step 4: estimate liq amount
                liqAmount += _estimateLiqAmount(req_.superformsData[i].liqRequests);

                /// @dev step 5: estimate dst swap cost if it exists
                totalDstGas += _estimateSwapFees(req_.dstChainIds[i], req_.superformsData[i].hasDstSwaps);
            }

            /// @dev step 6: estimate execution costs in dst (withdraw / deposit)
            /// note: execution cost includes acknowledgement messaging cost
            totalDstGas += _estimateDstExecutionCost(isDeposit_, req_.dstChainIds[i], superformIdsLen);

            /// @dev step 6: estimate if timelock form processing costs are involved
            if (!isDeposit_) {
                for (uint256 j; j < superformIdsLen; ++j) {
                    (, uint32 formId,) = req_.superformsData[i].superformIds[j].getSuperform();
                    if (formId == TIMELOCK_FORM_ID) {
                        totalDstGas += timelockCost[req_.dstChainIds[i]];
                    }
                }
            }

            /// @dev step 7: convert all dst gas estimates to src chain estimate  (withdraw / deposit)
            dstAmount += _convertToNativeFee(req_.dstChainIds[i], totalDstGas);
        }

        totalAmount = srcAmount + dstAmount + liqAmount;
    }

    /// @inheritdoc IPaymentHelper
    function estimateMultiDstSingleVault(
        MultiDstSingleVaultStateReq calldata req_,
        bool isDeposit_
    )
        external
        view
        override
        returns (uint256 liqAmount, uint256 srcAmount, uint256 dstAmount, uint256 totalAmount)
    {
        uint256 len = req_.dstChainIds.length;
        for (uint256 i; i < len; ++i) {
            uint256 totalDstGas;

            /// @dev step 1: estimate amb costs
            uint256 ambFees = _estimateAMBFees(
                req_.ambIds[i], req_.dstChainIds[i], _generateSingleVaultMessage(req_.superformsData[i])
            );

            srcAmount += ambFees;

            if (isDeposit_) {
                /// @dev step 2: estimate update cost (only for deposit)
                totalDstGas += _estimateUpdateCost(req_.dstChainIds[i], 1);

                /// @dev step 3: estimation execution cost of acknowledgement
                srcAmount += _estimateAckProcessingCost(1);

                /// @dev step 4: estimate the liqAmount
                liqAmount += _estimateLiqAmount(req_.superformsData[i].liqRequest.castLiqRequestToArray());

                /// @dev step 5: estimate if swap costs are involved
                totalDstGas +=
                    _estimateSwapFees(req_.dstChainIds[i], req_.superformsData[i].hasDstSwap.castBoolToArray());
            }

            /// @dev step 5: estimate execution costs in dst
            /// note: execution cost includes acknowledgement messaging cost
            totalDstGas += _estimateDstExecutionCost(isDeposit_, req_.dstChainIds[i], 1);

            /// @dev step 6: estimate if timelock form processing costs are involved
            (, uint32 formId,) = req_.superformsData[i].superformId.getSuperform();
            if (!isDeposit_ && formId == TIMELOCK_FORM_ID) {
                totalDstGas += timelockCost[req_.dstChainIds[i]];
            }

            /// @dev step 7: convert all dst gas estimates to src chain estimate
            dstAmount += _convertToNativeFee(req_.dstChainIds[i], totalDstGas);
        }

        totalAmount = srcAmount + dstAmount + liqAmount;
    }

    /// @inheritdoc IPaymentHelper
    function estimateSingleXChainMultiVault(
        SingleXChainMultiVaultStateReq calldata req_,
        bool isDeposit_
    )
        external
        view
        override
        returns (uint256 liqAmount, uint256 srcAmount, uint256 dstAmount, uint256 totalAmount)
    {
        uint256 totalDstGas;
        uint256 superformIdsLen = req_.superformsData.superformIds.length;

        /// @dev step 1: estimate amb costs
        uint256 ambFees =
            _estimateAMBFees(req_.ambIds, req_.dstChainId, _generateMultiVaultMessage(req_.superformsData));

        srcAmount += ambFees;

        /// @dev step 2: estimate update cost (only for deposit)
        if (isDeposit_) totalDstGas += _estimateUpdateCost(req_.dstChainId, superformIdsLen);

        /// @dev step 3: estimate execution costs in dst
        /// note: execution cost includes acknowledgement messaging cost
        totalDstGas += _estimateDstExecutionCost(isDeposit_, req_.dstChainId, superformIdsLen);

        /// @dev step 4: estimation execution cost of acknowledgement
        if (isDeposit_) srcAmount += _estimateAckProcessingCost(superformIdsLen);

        /// @dev step 5: estimate liq amount
        if (isDeposit_) liqAmount += _estimateLiqAmount(req_.superformsData.liqRequests);

        /// @dev step 6: estimate if swap costs are involved
        if (isDeposit_) totalDstGas += _estimateSwapFees(req_.dstChainId, req_.superformsData.hasDstSwaps);

        /// @dev step 7: estimate if timelock form processing costs are involved
        if (!isDeposit_) {
            for (uint256 i; i < superformIdsLen; ++i) {
                (, uint32 formId,) = req_.superformsData.superformIds[i].getSuperform();

                if (formId == TIMELOCK_FORM_ID) {
                    totalDstGas += timelockCost[CHAIN_ID];
                }
            }
        }

        /// @dev step 8: convert all dst gas estimates to src chain estimate
        dstAmount += _convertToNativeFee(req_.dstChainId, totalDstGas);

        totalAmount = srcAmount + dstAmount + liqAmount;
    }

    /// @inheritdoc IPaymentHelper
    function estimateSingleXChainSingleVault(
        SingleXChainSingleVaultStateReq calldata req_,
        bool isDeposit_
    )
        external
        view
        override
        returns (uint256 liqAmount, uint256 srcAmount, uint256 dstAmount, uint256 totalAmount)
    {
        uint256 totalDstGas;
        /// @dev step 1: estimate amb costs
        uint256 ambFees =
            _estimateAMBFees(req_.ambIds, req_.dstChainId, _generateSingleVaultMessage(req_.superformData));

        srcAmount += ambFees;

        /// @dev step 2: estimate update cost (only for deposit)
        if (isDeposit_) totalDstGas += _estimateUpdateCost(req_.dstChainId, 1);

        /// @dev step 3: estimate execution costs in dst
        /// note: execution cost includes acknowledgement messaging cost
        totalDstGas += _estimateDstExecutionCost(isDeposit_, req_.dstChainId, 1);

        /// @dev step 4: estimation execution cost of acknowledgement
        if (isDeposit_) srcAmount += _estimateAckProcessingCost(1);

        /// @dev step 5: estimate the liq amount
        if (isDeposit_) liqAmount += _estimateLiqAmount(req_.superformData.liqRequest.castLiqRequestToArray());

        /// @dev step 6: estimate if swap costs are involved
        if (isDeposit_) {
            totalDstGas += _estimateSwapFees(req_.dstChainId, req_.superformData.hasDstSwap.castBoolToArray());
        }

        /// @dev step 7: estimate if timelock form processing costs are involved
        (, uint32 formId,) = req_.superformData.superformId.getSuperform();
        if (!isDeposit_ && formId == TIMELOCK_FORM_ID) {
            totalDstGas += timelockCost[CHAIN_ID];
        }

        /// @dev step 8: convert all dst gas estimates to src chain estimate
        dstAmount += _convertToNativeFee(req_.dstChainId, totalDstGas);

        totalAmount = srcAmount + dstAmount + liqAmount;
    }

    /// @inheritdoc IPaymentHelper
    function estimateSingleDirectSingleVault(
        SingleDirectSingleVaultStateReq calldata req_,
        bool isDeposit_
    )
        external
        view
        override
        returns (uint256 liqAmount, uint256 srcAmount, uint256 totalAmount)
    {
        (, uint32 formId,) = req_.superformData.superformId.getSuperform();
        /// @dev only if timelock form withdrawal is involved
        if (!isDeposit_ && formId == TIMELOCK_FORM_ID) {
            srcAmount += timelockCost[CHAIN_ID] * _getGasPrice(CHAIN_ID);
        }

        if (isDeposit_) liqAmount += _estimateLiqAmount(req_.superformData.liqRequest.castLiqRequestToArray());

        /// @dev not adding dstAmount to save some GAS
        totalAmount = liqAmount + srcAmount;
    }

    /// @inheritdoc IPaymentHelper
    function estimateSingleDirectMultiVault(
        SingleDirectMultiVaultStateReq calldata req_,
        bool isDeposit_
    )
        external
        view
        override
        returns (uint256 liqAmount, uint256 srcAmount, uint256 totalAmount)
    {
        uint256 len = req_.superformData.superformIds.length;
        for (uint256 i; i < len; ++i) {
            (, uint32 formId,) = req_.superformData.superformIds[i].getSuperform();
            uint256 timelockPrice = timelockCost[uint64(block.chainid)] * _getGasPrice(uint64(block.chainid));
            /// @dev only if timelock form withdrawal is involved
            if (!isDeposit_ && formId == TIMELOCK_FORM_ID) {
                srcAmount += timelockPrice;
            }
        }

        if (isDeposit_) liqAmount += _estimateLiqAmount(req_.superformData.liqRequests);

        /// @dev not adding dstAmount to save some GAS
        totalAmount = liqAmount + srcAmount;
    }

    /// @inheritdoc IPaymentHelper
    function estimateAMBFees(
        uint8[] memory ambIds_,
        uint64 dstChainId_,
        bytes memory message_,
        bytes[] memory extraData_
    )
        public
        view
        returns (uint256 totalFees, uint256[] memory)
    {
        uint256 len = ambIds_.length;
        uint256[] memory fees = new uint256[](len);

        /// @dev just checks the estimate for sending message from src -> dst
        for (uint256 i; i < len; ++i) {
            fees[i] = CHAIN_ID != dstChainId_
                ? IAmbImplementation(superRegistry.getAmbAddress(ambIds_[i])).estimateFees(
                    dstChainId_, message_, extraData_[i]
                )
                : 0;

            totalFees += fees[i];
        }

        return (totalFees, fees);
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL WRITE FUNCTIONS                    //
    //////////////////////////////////////////////////////////////

    /// @inheritdoc IPaymentHelper
    function addRemoteChain(
        uint64 chainId_,
        PaymentHelperConfig calldata config_
    )
        external
        override
        onlyProtocolAdmin
    {
        if (config_.nativeFeedOracle != address(0)) {
            nativeFeedOracle[chainId_] = AggregatorV3Interface(config_.nativeFeedOracle);
        }

        if (config_.gasPriceOracle != address(0)) {
            gasPriceOracle[chainId_] = AggregatorV3Interface(config_.gasPriceOracle);
        }

        swapGasUsed[chainId_] = config_.swapGasUsed;
        updateGasUsed[chainId_] = config_.updateGasUsed;
        depositGasUsed[chainId_] = config_.depositGasUsed;
        withdrawGasUsed[chainId_] = config_.withdrawGasUsed;
        nativePrice[chainId_] = config_.defaultNativePrice;
        gasPrice[chainId_] = config_.defaultGasPrice;
        gasPerByte[chainId_] = config_.dstGasPerByte;
        ackGasCost[chainId_] = config_.ackGasCost;
        timelockCost[chainId_] = config_.timelockCost;
    }

    /// @inheritdoc IPaymentHelper
    function updateRemoteChain(
        uint64 chainId_,
        uint256 configType_,
        bytes memory config_
    )
        external
        override
        onlyEmergencyAdmin
    {
        /// @dev Type 1: DST TOKEN PRICE FEED ORACLE
        if (configType_ == 1) {
            nativeFeedOracle[chainId_] = AggregatorV3Interface(abi.decode(config_, (address)));
        }

        /// @dev Type 2: DST GAS PRICE ORACLE
        if (configType_ == 2) {
            gasPriceOracle[chainId_] = AggregatorV3Interface(abi.decode(config_, (address)));
        }

        /// @dev Type 3: SWAP GAS USED
        if (configType_ == 3) {
            swapGasUsed[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 4: PAYLOAD UPDATE GAS COST PER TX FOR DEPOSIT
        if (configType_ == 4) {
            updateGasUsed[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 5: DEPOSIT GAS COST PER TX
        if (configType_ == 5) {
            depositGasUsed[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 6: WITHDRAW GAS COST PER TX
        if (configType_ == 6) {
            withdrawGasUsed[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 7: DEFAULT NATIVE PRICE
        if (configType_ == 7) {
            nativePrice[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 8: DEFAULT GAS PRICE
        if (configType_ == 8) {
            gasPrice[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 9: GAS PRICE PER Byte of Message
        if (configType_ == 9) {
            gasPerByte[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 10: ACK GAS COST
        if (configType_ == 10) {
            ackGasCost[chainId_] = abi.decode(config_, (uint256));
        }

        /// @dev Type 11: TIMELOCK PROCESSING COST
        if (configType_ == 11) {
            timelockCost[chainId_] = abi.decode(config_, (uint256));
        }

        emit ChainConfigUpdated(chainId_, configType_, config_);
    }

    /// @inheritdoc IPaymentHelper
    function updateRegisterAERC20Params(
        uint256 totalTransmuterFees_,
        bytes memory extraDataForTransmuter_
    )
        external
        onlyEmergencyAdmin
    {
        totalTransmuterFees = totalTransmuterFees_;
        extraDataForTransmuter = extraDataForTransmuter_;
    }

    //////////////////////////////////////////////////////////////
    //                  INTERNAL FUNCTIONS                      //
    //////////////////////////////////////////////////////////////

    /// @dev helps generate extra data per amb
    function _generateExtraData(
        uint64 dstChainId_,
        uint8[] memory ambIds_,
        bytes memory message_
    )
        internal
        view
        returns (bytes[] memory extraDataPerAMB)
    {
        AMBMessage memory ambIdEncodedMessage = abi.decode(message_, (AMBMessage));
        ambIdEncodedMessage.params = abi.encode(ambIds_, ambIdEncodedMessage.params);

        uint256 len = ambIds_.length;
        uint256 gasReqPerByte = gasPerByte[dstChainId_];
        uint256 totalDstGasReqInWei = abi.encode(ambIdEncodedMessage).length * gasReqPerByte;

        AMBMessage memory decodedMessage = abi.decode(message_, (AMBMessage));
        decodedMessage.params = message_.computeProofBytes();

        uint256 totalDstGasReqInWeiForProof = abi.encode(decodedMessage).length * gasReqPerByte;

        extraDataPerAMB = new bytes[](len);

        for (uint256 i; i < len; ++i) {
            uint256 gasReq = i != 0 ? totalDstGasReqInWeiForProof : totalDstGasReqInWei;

            /// @dev amb id 1: layerzero
            /// @dev amb id 2: hyperlane
            /// @dev amb id 3: wormhole

            /// @notice id 1: encoded layerzero adapter params (version 2). Other values are not used atm.
            /// @notice id 2: encoded dst gas limit
            /// @notice id 3: encoded dst gas limit
            if (ambIds_[i] == 1) {
                extraDataPerAMB[i] = abi.encodePacked(uint16(2), gasReq, uint256(0), address(0));
            } else if (ambIds_[i] == 2) {
                extraDataPerAMB[i] = abi.encode(gasReq);
            } else if (ambIds_[i] == 3) {
                extraDataPerAMB[i] = abi.encode(0, gasReq);
            }
        }
    }

    /// @dev helps estimate the acknowledgement costs for amb processing
    function estimateAckCost(uint256 payloadId_) external view returns (uint256 totalFees) {
        EstimateAckCostVars memory v;
        IBaseStateRegistry coreStateRegistry =
            IBaseStateRegistry(superRegistry.getAddress(keccak256("CORE_STATE_REGISTRY")));
        v.currPayloadId = coreStateRegistry.payloadsCount();

        if (payloadId_ > v.currPayloadId) revert Error.INVALID_PAYLOAD_ID();

        v.payloadHeader = coreStateRegistry.payloadHeader(payloadId_);
        v.payloadBody = coreStateRegistry.payloadBody(payloadId_);

        (, v.callbackType, v.isMulti,,, v.srcChainId) = DataLib.decodeTxInfo(v.payloadHeader);

        /// if callback type is return then return 0
        if (v.callbackType != 0) return 0;

        if (v.isMulti == 1) {
            InitMultiVaultData memory data = abi.decode(v.payloadBody, (InitMultiVaultData));
            v.payloadBody = abi.encode(ReturnMultiData(v.currPayloadId, data.superformIds, data.amounts));
        } else {
            InitSingleVaultData memory data = abi.decode(v.payloadBody, (InitSingleVaultData));
            v.payloadBody = abi.encode(ReturnSingleData(v.currPayloadId, data.superformId, data.amount));
        }

        v.ackAmbIds = coreStateRegistry.getMessageAMB(payloadId_);

        v.message = abi.encode(AMBMessage(coreStateRegistry.payloadHeader(payloadId_), v.payloadBody));

        return _estimateAMBFees(v.ackAmbIds, v.srcChainId, v.message);
    }

    /// @dev helps estimate the cross-chain message costs
    function _estimateAMBFees(
        uint8[] memory ambIds_,
        uint64 dstChainId_,
        bytes memory message_
    )
        internal
        view
        returns (uint256 totalFees)
    {
        uint256 len = ambIds_.length;

        bytes[] memory extraDataPerAMB = _generateExtraData(dstChainId_, ambIds_, message_);

        AMBMessage memory ambIdEncodedMessage = abi.decode(message_, (AMBMessage));
        ambIdEncodedMessage.params = abi.encode(ambIds_, ambIdEncodedMessage.params);

        bytes memory proof_ = abi.encode(AMBMessage(type(uint256).max, abi.encode(keccak256(message_))));

        /// @dev just checks the estimate for sending message from src -> dst
        /// @dev only ambIds_[0] = primary amb (rest of the ambs send only the proof)
        for (uint256 i; i < len; ++i) {
            uint256 tempFee = CHAIN_ID != dstChainId_
                ? IAmbImplementation(superRegistry.getAmbAddress(ambIds_[i])).estimateFees(
                    dstChainId_, i != 0 ? proof_ : abi.encode(ambIdEncodedMessage), extraDataPerAMB[i]
                )
                : 0;

            totalFees += tempFee;
        }
    }

    /// @dev helps estimate the cross-chain message costs
    function _estimateAMBFeesReturnExtraData(
        uint64 dstChainId_,
        uint8[] calldata ambIds_,
        bytes memory message_
    )
        internal
        view
        returns (uint256[] memory feeSplitUp, bytes[] memory extraDataPerAMB, uint256 totalFees)
    {
        AMBMessage memory ambIdEncodedMessage = abi.decode(message_, (AMBMessage));
        ambIdEncodedMessage.params = abi.encode(ambIds_, ambIdEncodedMessage.params);

        uint256 len = ambIds_.length;

        extraDataPerAMB = _generateExtraData(dstChainId_, ambIds_, message_);

        feeSplitUp = new uint256[](len);

        bytes memory proof_ = abi.encode(AMBMessage(type(uint256).max, abi.encode(keccak256(message_))));

        /// @dev just checks the estimate for sending message from src -> dst
        for (uint256 i; i < len; ++i) {
            uint256 tempFee = CHAIN_ID != dstChainId_
                ? IAmbImplementation(superRegistry.getAmbAddress(ambIds_[i])).estimateFees(
                    dstChainId_, i != 0 ? proof_ : abi.encode(ambIdEncodedMessage), extraDataPerAMB[i]
                )
                : 0;

            totalFees += tempFee;
            feeSplitUp[i] = tempFee;
        }
    }

    /// @dev helps estimate the liq amount involved in the tx
    function _estimateLiqAmount(LiqRequest[] memory req_) internal pure returns (uint256 liqAmount) {
        uint256 len = req_.length;
        for (uint256 i; i < len; ++i) {
            liqAmount += req_[i].nativeAmount;
        }
    }

    /// @dev helps estimate the dst chain swap gas limit (if multi-tx is involved)
    function _estimateSwapFees(
        uint64 dstChainId_,
        bool[] memory hasDstSwaps_
    )
        internal
        view
        returns (uint256 gasUsed)
    {
        uint256 totalSwaps;

        if (CHAIN_ID == dstChainId_) {
            return 0;
        }

        uint256 len = hasDstSwaps_.length;
        for (uint256 i; i < len; ++i) {
            /// @dev checks if hasDstSwap is true
            if (hasDstSwaps_[i]) {
                ++totalSwaps;
            }
        }

        if (totalSwaps == 0) {
            return 0;
        }

        return totalSwaps * swapGasUsed[dstChainId_];
    }

    /// @dev helps estimate the dst chain update payload gas limit
    function _estimateUpdateCost(uint64 dstChainId_, uint256 vaultsCount_) internal view returns (uint256 gasUsed) {
        return vaultsCount_ * updateGasUsed[dstChainId_];
    }

    /// @dev helps estimate the dst chain processing gas limit
    function _estimateDstExecutionCost(
        bool isDeposit_,
        uint64 dstChainId_,
        uint256 vaultsCount_
    )
        internal
        view
        returns (uint256 gasUsed)
    {
        uint256 executionGasPerVault = isDeposit_ ? depositGasUsed[dstChainId_] : withdrawGasUsed[dstChainId_];

        return executionGasPerVault * vaultsCount_;
    }

    /// @dev helps estimate the src chain processing fee
    function _estimateAckProcessingCost(uint256 vaultsCount_) internal view returns (uint256 nativeFee) {
        uint256 gasCost = vaultsCount_ * ackGasCost[CHAIN_ID];

        return gasCost * _getGasPrice(CHAIN_ID);
    }

    /// @dev generates the amb message for single vault data
    function _generateSingleVaultMessage(SingleVaultSFData memory sfData_)
        internal
        view
        returns (bytes memory message_)
    {
        bytes memory ambData = abi.encode(
            InitSingleVaultData(
                _getNextPayloadId(),
                sfData_.superformId,
                sfData_.amount,
                sfData_.maxSlippage,
                sfData_.liqRequest,
                sfData_.hasDstSwap,
                sfData_.retain4626,
                sfData_.receiverAddress,
                sfData_.extraFormData
            )
        );
        message_ = abi.encode(AMBMessage(type(uint256).max, ambData));
    }

    /// @dev generates the amb message for multi vault data
    function _generateMultiVaultMessage(MultiVaultSFData memory sfData_)
        internal
        view
        returns (bytes memory message_)
    {
        bytes memory ambData = abi.encode(
            InitMultiVaultData(
                _getNextPayloadId(),
                sfData_.superformIds,
                sfData_.amounts,
                sfData_.maxSlippages,
                sfData_.liqRequests,
                sfData_.hasDstSwaps,
                sfData_.retain4626s,
                sfData_.receiverAddress,
                sfData_.extraFormData
            )
        );
        message_ = abi.encode(AMBMessage(type(uint256).max, ambData));
    }

    /// @dev helps convert the dst gas fee into src chain native fee
    /// @dev https://docs.soliditylang.org/en/v0.8.4/units-and-global-variables.html#ether-units
    /// @dev all native tokens should be 18 decimals across all EVMs
    function _convertToNativeFee(uint64 dstChainId_, uint256 dstGas_) internal view returns (uint256 nativeFee) {
        /// @dev gas fee * gas price (to get the gas amounts in dst chain's native token)
        /// @dev gas price is 9 decimal (in gwei)
        /// @dev assumption: all evm native tokens are 18 decimals
        uint256 dstNativeFee = dstGas_ * _getGasPrice(dstChainId_);

        if (dstNativeFee == 0) {
            return 0;
        }

        /// @dev converts the gas to pay in terms of native token to usd value
        /// @dev native token price is 8 decimal
        uint256 dstUsdValue = dstNativeFee * _getNativeTokenPrice(dstChainId_); // native token price - 8 decimal

        if (dstUsdValue == 0) {
            return 0;
        }

        /// @dev converts the usd value to source chain's native token
        /// @dev native token price is 8 decimal which cancels the 8 decimal multiplied in previous step
        nativeFee = (dstUsdValue) / _getNativeTokenPrice(CHAIN_ID);
    }

    /// @dev helps generate the new payload id
    /// @dev next payload id = current payload id + 1
    function _getNextPayloadId() internal view returns (uint256 nextPayloadId) {
        nextPayloadId = ReadOnlyBaseRegistry(superRegistry.getAddress(keccak256("CORE_STATE_REGISTRY"))).payloadsCount();
        ++nextPayloadId;
    }

    /// @dev helps return the current gas price of different networks
    /// @return native token price
    function _getGasPrice(uint64 chainId_) internal view returns (uint256) {
        address oracleAddr = address(gasPriceOracle[chainId_]);
        if (oracleAddr != address(0)) {
            (, int256 value,, uint256 updatedAt,) = AggregatorV3Interface(oracleAddr).latestRoundData();
            if (value <= 0) revert Error.CHAINLINK_MALFUNCTION();
            if (updatedAt == 0) revert Error.CHAINLINK_INCOMPLETE_ROUND();
            return uint256(value);
        }

        return gasPrice[chainId_];
    }

    /// @dev helps return the dst chain token price of different networks
    /// @return native token price
    function _getNativeTokenPrice(uint64 chainId_) internal view returns (uint256) {
        address oracleAddr = address(nativeFeedOracle[chainId_]);
        if (oracleAddr != address(0)) {
            (, int256 dstTokenPrice,, uint256 updatedAt,) = AggregatorV3Interface(oracleAddr).latestRoundData();
            if (dstTokenPrice <= 0) revert Error.CHAINLINK_MALFUNCTION();
            if (updatedAt == 0) revert Error.CHAINLINK_INCOMPLETE_ROUND();
            return uint256(dstTokenPrice);
        }

        return nativePrice[chainId_];
    }
}
