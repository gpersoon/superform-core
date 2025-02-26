// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { IDstSwapper } from "../interfaces/IDstSwapper.sol";
import { ISuperRegistry } from "../interfaces/ISuperRegistry.sol";
import { IBaseStateRegistry } from "../interfaces/IBaseStateRegistry.sol";
import { IBridgeValidator } from "../interfaces/IBridgeValidator.sol";
import { LiquidityHandler } from "../crosschain-liquidity/LiquidityHandler.sol";
import { ISuperRBAC } from "../interfaces/ISuperRBAC.sol";
import { IERC4626Form } from "../forms/interfaces/IERC4626Form.sol";
import { Error } from "../libraries/Error.sol";
import { DataLib } from "../libraries/DataLib.sol";
import "../types/DataTypes.sol";

/// @title DstSwapper
/// @author Zeropoint Labs.
/// @dev handles all destination chain swaps.
contract DstSwapper is IDstSwapper, ReentrancyGuard, LiquidityHandler {
    using SafeERC20 for IERC20;

    //////////////////////////////////////////////////////////////
    //                         CONSTANTS                         //
    //////////////////////////////////////////////////////////////

    ISuperRegistry public immutable superRegistry;
    uint64 public immutable CHAIN_ID;

    //////////////////////////////////////////////////////////////
    //                     STATE VARIABLES                      //
    //////////////////////////////////////////////////////////////

    mapping(uint256 payloadId => mapping(uint256 index => FailedSwap)) internal failedSwap;
    mapping(uint256 payloadId => mapping(uint256 index => uint256 amount)) public swappedAmount;

    //////////////////////////////////////////////////////////////
    //                           STRUCTS                         //
    //////////////////////////////////////////////////////////////

    struct ProcessTxVars {
        address finalDst;
        address to;
        address underlying;
        address approvalToken;
        address interimToken;
        uint256 amount;
        uint256 expAmount;
        uint256 maxSlippage;
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 balanceDiff;
        uint64 chainId;
    }

    //////////////////////////////////////////////////////////////
    //                       MODIFIERS                          //
    //////////////////////////////////////////////////////////////

    modifier onlySwapper() {
        bytes32 role = keccak256("DST_SWAPPER_ROLE");
        if (!ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasRole(role, msg.sender)) {
            revert Error.NOT_PRIVILEGED_CALLER(role);
        }
        _;
    }

    modifier onlyCoreStateRegistry() {
        if (superRegistry.getAddress(keccak256("CORE_STATE_REGISTRY")) != msg.sender) {
            revert Error.NOT_CORE_STATE_REGISTRY();
        }
        _;
    }

    //////////////////////////////////////////////////////////////
    //                      CONSTRUCTOR                         //
    //////////////////////////////////////////////////////////////

    /// @param superRegistry_ superform registry contract
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

    /// @inheritdoc IDstSwapper
    function getPostDstSwapFailureUpdatedTokenAmount(
        uint256 payloadId_,
        uint256 index_
    )
        external
        view
        override
        returns (address interimToken, uint256 amount)
    {
        interimToken = failedSwap[payloadId_][index_].interimToken;
        amount = failedSwap[payloadId_][index_].amount;

        if (amount == 0) {
            revert Error.INVALID_DST_SWAPPER_FAILED_SWAP();
        } else {
            if (interimToken == NATIVE) {
                if (address(this).balance < amount) {
                    revert Error.INVALID_DST_SWAPPER_FAILED_SWAP_NO_NATIVE_BALANCE();
                }
            } else {
                if (IERC20(interimToken).balanceOf(address(this)) < amount) {
                    revert Error.INVALID_DST_SWAPPER_FAILED_SWAP_NO_TOKEN_BALANCE();
                }
            }
        }
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL WRITE FUNCTIONS                    //
    //////////////////////////////////////////////////////////////

    /// @notice receive enables processing native token transfers into the smart contract.
    /// @dev liquidity bridge fails without a native receive function.
    receive() external payable { }

    /// @inheritdoc IDstSwapper
    function processTx(
        uint256 payloadId_,
        uint256 index_,
        uint8 bridgeId_,
        bytes calldata txData_
    )
        external
        override
        onlySwapper
        nonReentrant
    {
        IBaseStateRegistry coreStateRegistry = _getCoreStateRegistry();

        _isValidPayloadId(payloadId_, coreStateRegistry);

        (,, uint8 multi,,,) = DataLib.decodeTxInfo(coreStateRegistry.payloadHeader(payloadId_));

        if (multi != 0) revert Error.INVALID_PAYLOAD_TYPE();

        _processTx(
            payloadId_,
            index_,
            bridgeId_,
            txData_,
            abi.decode(coreStateRegistry.payloadBody(payloadId_), (InitSingleVaultData)).liqData.interimToken,
            coreStateRegistry
        );
    }

    /// @inheritdoc IDstSwapper
    function batchProcessTx(
        uint256 payloadId_,
        uint256[] calldata indices,
        uint8[] calldata bridgeIds_,
        bytes[] calldata txData_
    )
        external
        override
        onlySwapper
        nonReentrant
    {
        IBaseStateRegistry coreStateRegistry = _getCoreStateRegistry();

        _isValidPayloadId(payloadId_, coreStateRegistry);

        (,, uint8 multi,,,) = DataLib.decodeTxInfo(coreStateRegistry.payloadHeader(payloadId_));
        if (multi != 1) revert Error.INVALID_PAYLOAD_TYPE();

        InitMultiVaultData memory data = abi.decode(coreStateRegistry.payloadBody(payloadId_), (InitMultiVaultData));

        uint256 len = txData_.length;
        for (uint256 i; i < len; ++i) {
            _processTx(
                payloadId_, indices[i], bridgeIds_[i], txData_[i], data.liqData[i].interimToken, coreStateRegistry
            );
        }
    }

    /// @inheritdoc IDstSwapper
    function updateFailedTx(
        uint256 payloadId_,
        uint256 index_,
        address interimToken_,
        uint256 amount_
    )
        external
        override
        onlySwapper
    {
        IBaseStateRegistry coreStateRegistry = _getCoreStateRegistry();

        _isValidPayloadId(payloadId_, coreStateRegistry);

        (,, uint8 multi,,,) = DataLib.decodeTxInfo(coreStateRegistry.payloadHeader(payloadId_));

        if (multi != 0) revert Error.INVALID_PAYLOAD_TYPE();

        _updateFailedTx(
            payloadId_,
            index_,
            interimToken_,
            abi.decode(coreStateRegistry.payloadBody(payloadId_), (InitSingleVaultData)).liqData.interimToken,
            amount_,
            coreStateRegistry
        );
    }

    /// @inheritdoc IDstSwapper
    function batchUpdateFailedTx(
        uint256 payloadId_,
        uint256[] calldata indices_,
        address[] calldata interimTokens_,
        uint256[] calldata amounts_
    )
        external
        override
        onlySwapper
    {
        uint256 len = indices_.length;

        IBaseStateRegistry coreStateRegistry = _getCoreStateRegistry();

        _isValidPayloadId(payloadId_, coreStateRegistry);

        (,, uint8 multi,,,) = DataLib.decodeTxInfo(coreStateRegistry.payloadHeader(payloadId_));
        if (multi != 1) revert Error.INVALID_PAYLOAD_TYPE();

        InitMultiVaultData memory data = abi.decode(coreStateRegistry.payloadBody(payloadId_), (InitMultiVaultData));

        for (uint256 i; i < len; ++i) {
            _updateFailedTx(
                payloadId_, indices_[i], interimTokens_[i], data.liqData[i].interimToken, amounts_[i], coreStateRegistry
            );
        }
    }

    /// @inheritdoc IDstSwapper
    function processFailedTx(
        address user_,
        address interimToken_,
        uint256 amount_
    )
        external
        override
        onlyCoreStateRegistry
    {
        if (user_ == address(0)) revert Error.ZERO_ADDRESS();
        if (interimToken_ != NATIVE) {
            IERC20(interimToken_).safeTransfer(user_, amount_);
        } else {
            (bool success,) = payable(user_).call{ value: amount_ }("");
            if (!success) revert Error.FAILED_TO_SEND_NATIVE();
        }
    }

    //////////////////////////////////////////////////////////////
    //                  INTERNAL FUNCTIONS                      //
    //////////////////////////////////////////////////////////////

    function _getCoreStateRegistry() internal view returns (IBaseStateRegistry) {
        return IBaseStateRegistry(superRegistry.getAddress(keccak256("CORE_STATE_REGISTRY")));
    }

    function _isValidPayloadId(uint256 payloadId_, IBaseStateRegistry coreStateRegistry) internal view {
        if (payloadId_ > coreStateRegistry.payloadsCount()) {
            revert Error.INVALID_PAYLOAD_ID();
        }
    }

    function _processTx(
        uint256 payloadId_,
        uint256 index_,
        uint8 bridgeId_,
        bytes calldata txData_,
        address userSuppliedInterimToken_,
        IBaseStateRegistry coreStateRegistry_
    )
        internal
    {
        if (swappedAmount[payloadId_][index_] != 0) {
            revert Error.DST_SWAP_ALREADY_PROCESSED();
        }

        ProcessTxVars memory v;
        v.chainId = CHAIN_ID;

        IBridgeValidator validator = IBridgeValidator(superRegistry.getBridgeValidator(bridgeId_));
        (v.approvalToken, v.amount) = validator.decodeDstSwap(txData_);

        if (userSuppliedInterimToken_ != v.approvalToken) {
            revert Error.INVALID_INTERIM_TOKEN();
        }

        v.finalDst = address(coreStateRegistry_);

        /// @dev validates the bridge data
        validator.validateTxData(
            IBridgeValidator.ValidateTxDataArgs(
                txData_,
                v.chainId,
                v.chainId,
                v.chainId,
                false,
                /// @dev to enter the if-else case of the bridge validator loop
                address(0),
                v.finalDst,
                v.approvalToken,
                address(0)
            )
        );

        /// @dev get the address of the bridge to send the txData to.
        (v.underlying, v.expAmount, v.maxSlippage) = _getFormUnderlyingFrom(coreStateRegistry_, payloadId_, index_);

        v.balanceBefore = IERC20(v.underlying).balanceOf(v.finalDst);

        _dispatchTokens(
            superRegistry.getBridgeAddress(bridgeId_),
            txData_,
            v.approvalToken,
            v.amount,
            v.approvalToken == NATIVE ? v.amount : 0
        );

        v.balanceAfter = IERC20(v.underlying).balanceOf(v.finalDst);

        if (v.balanceAfter <= v.balanceBefore) {
            revert Error.INVALID_SWAP_OUTPUT();
        }

        v.balanceDiff = v.balanceAfter - v.balanceBefore;

        /// @dev if actual underlying is less than expAmount adjusted
        /// with maxSlippage, invariant breaks
        /// @notice that unlike in CoreStateRegistry slippage check inside updateDeposit, in here we don't check for
        /// negative slippage
        /// @notice this essentially allows any amount to be swapped, (the invariant will still break if the amount is
        /// too low)
        /// @notice this doesn't mean that the keeper or the user can swap any amount, because of the 2nd slippage check
        /// in CoreStateRegistry
        /// @notice in this check, we check if there is negative slippage, for which case, the user is capped to receive
        /// the v.expAmount of tokens (originally defined)
        if (v.balanceDiff < ((v.expAmount * (10_000 - v.maxSlippage)) / 10_000)) {
            revert Error.SLIPPAGE_OUT_OF_BOUNDS();
        }

        /// @dev updates swapped amount
        swappedAmount[payloadId_][index_] = v.balanceDiff;

        /// @dev emits final event
        emit SwapProcessed(payloadId_, index_, bridgeId_, v.balanceDiff);
    }

    function _updateFailedTx(
        uint256 payloadId_,
        uint256 index_,
        address interimToken_,
        address userSuppliedInterimToken_,
        uint256 amount_,
        IBaseStateRegistry coreStateRegistry
    )
        internal
    {
        PayloadState currState = coreStateRegistry.payloadTracking(payloadId_);

        if (currState != PayloadState.STORED) {
            revert Error.INVALID_PAYLOAD_STATUS();
        }

        if (userSuppliedInterimToken_ != interimToken_) {
            revert Error.INVALID_INTERIM_TOKEN();
        }

        if (failedSwap[payloadId_][index_].amount != 0) {
            revert Error.FAILED_DST_SWAP_ALREADY_UPDATED();
        }

        if (amount_ == 0) {
            revert Error.ZERO_AMOUNT();
        }

        if (interimToken_ != NATIVE) {
            if (IERC20(interimToken_).balanceOf(address(this)) < amount_) {
                revert Error.INSUFFICIENT_BALANCE();
            }
        } else {
            if (address(this).balance < amount_) {
                revert Error.INSUFFICIENT_BALANCE();
            }
        }

        /// @dev updates swapped amount
        failedSwap[payloadId_][index_].amount = amount_;
        failedSwap[payloadId_][index_].interimToken = interimToken_;

        /// @dev emits final event
        emit SwapFailed(payloadId_, index_, interimToken_, amount_);
    }

    function _getFormUnderlyingFrom(
        IBaseStateRegistry coreStateRegistry_,
        uint256 payloadId_,
        uint256 index_
    )
        internal
        view
        returns (address underlying, uint256 amount, uint256 maxSlippage)
    {
        PayloadState currState = coreStateRegistry_.payloadTracking(payloadId_);

        if (currState != PayloadState.STORED) {
            revert Error.INVALID_PAYLOAD_STATUS();
        }

        uint256 payloadHeader = coreStateRegistry_.payloadHeader(payloadId_);
        bytes memory payload = coreStateRegistry_.payloadBody(payloadId_);

        (,, uint8 multi,,,) = DataLib.decodeTxInfo(payloadHeader);

        if (multi == 1) {
            InitMultiVaultData memory data = abi.decode(payload, (InitMultiVaultData));

            if (index_ >= data.superformIds.length) {
                revert Error.INVALID_INDEX();
            }

            (address superform,,) = DataLib.getSuperform(data.superformIds[index_]);
            underlying = IERC4626Form(superform).getVaultAsset();
            maxSlippage = data.maxSlippages[index_];
            amount = data.amounts[index_];
        } else {
            if (index_ != 0) {
                revert Error.INVALID_INDEX();
            }

            InitSingleVaultData memory data = abi.decode(payload, (InitSingleVaultData));
            (address superform,,) = DataLib.getSuperform(data.superformId);
            underlying = IERC4626Form(superform).getVaultAsset();
            maxSlippage = data.maxSlippage;
            amount = data.amount;
        }
    }
}
