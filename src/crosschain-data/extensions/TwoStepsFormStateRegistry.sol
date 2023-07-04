// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {ISuperRBAC} from "../../interfaces/ISuperRBAC.sol";
import {ISuperRegistry} from "../../interfaces/ISuperRegistry.sol";
import {ISuperPositions} from "../../interfaces/ISuperPositions.sol";
import {IERC4626TimelockForm} from "../../forms/interfaces/IERC4626TimelockForm.sol";
import {ITwoStepsFormStateRegistry} from "../../interfaces/ITwoStepsFormStateRegistry.sol";
import {Error} from "../../utils/Error.sol";
import {BaseStateRegistry} from "../BaseStateRegistry.sol";
import {AckAMBData, AMBExtraData, TransactionType, CallbackType, InitSingleVaultData, AMBMessage, ReturnSingleData, PayloadState} from "../../types/DataTypes.sol";
import {LiqRequest} from "../../types/LiquidityTypes.sol";
import {DataLib} from "../../libraries/DataLib.sol";
import "../../utils/DataPacking.sol";

/// @title TwoStepsFormStateRegistry
/// @author Zeropoint Labs
/// @notice handles communication in two stepped forms
contract TwoStepsFormStateRegistry is BaseStateRegistry, ITwoStepsFormStateRegistry {
    using DataLib for uint256;

    /*///////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    bytes32 immutable WITHDRAW_COOLDOWN_PERIOD = keccak256(abi.encodeWithSignature("WITHDRAW_COOLDOWN_PERIOD()"));

    enum TimeLockStatus {
        UNAVAILABLE,
        PENDING,
        PROCESSED
    }

    struct TimeLockPayload {
        uint8 isXChain;
        address srcSender;
        uint64 srcChainId;
        uint256 lockedTill;
        InitSingleVaultData data;
        TimeLockStatus status;
    }

    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev tracks the total time lock payloads
    uint256 public timeLockPayloadCounter;

    /// @dev stores the timelock payloads
    mapping(uint256 timeLockPayloadId => TimeLockPayload) public timeLockPayload;

    /// @dev allows only form to write to the receive paylod
    /// TODO: add only 2 step forms to write
    modifier onlyForm(uint256 superFormId) {
        (address superForm, , ) = _getSuperForm(superFormId);
        if (msg.sender != superForm) revert Error.NOT_SUPERFORM();
        _;
    }

    modifier isValidPayloadId(uint256 payloadId_) {
        if (payloadId_ > payloadsCount) {
            revert Error.INVALID_PAYLOAD_ID();
        }
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_, uint8 registryType_) BaseStateRegistry(superRegistry_, registryType_) {}

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITwoStepsFormStateRegistry
    function receivePayload(
        uint8 type_,
        address srcSender_,
        uint64 srcChainId_,
        uint256 lockedTill_,
        InitSingleVaultData memory data_
    ) external override onlyForm(data_.superFormId) {
        ++timeLockPayloadCounter;

        timeLockPayload[timeLockPayloadCounter] = TimeLockPayload(
            type_,
            srcSender_,
            srcChainId_,
            lockedTill_,
            data_,
            TimeLockStatus.PENDING
        );
    }

    /// @inheritdoc ITwoStepsFormStateRegistry
    function finalizePayload(
        uint256 timeLockPayloadId_,
        bytes memory ambOverride_
    ) external payable override onlyProcessor {
        TimeLockPayload memory p = timeLockPayload[timeLockPayloadId_];

        if (p.lockedTill > block.timestamp) {
            revert Error.LOCKED();
        }

        (address superForm, , ) = _getSuperForm(p.data.superFormId);

        IERC4626TimelockForm form = IERC4626TimelockForm(superForm);
        try form.withdrawAfterCoolDown(p.data.amount) {
            /// @dev transfers the collateral received
        } catch {
            /// @dev dispatch acknowledgement to mint shares back || mint shares back
            if (p.isXChain == 1) {
                (uint256 payloadId_, ) = abi.decode(p.data.extraFormData, (uint256, uint256));
                bytes memory message_ = _constructSingleReturnData(p.srcSender, p.srcChainId, payloadId_, p.data);

                _dispatchAcknowledgement(p.srcChainId, message_, ambOverride_);
            }

            if (p.isXChain == 0) {
                ISuperPositions(superRegistry.superPositions()).mintSingleSP(
                    p.srcSender,
                    p.data.superFormId,
                    p.data.amount
                );
            }
        }
    }

    /// @inheritdoc BaseStateRegistry
    function processPayload(
        uint256 payloadId_,
        bytes memory ackExtraData_
    ) external payable virtual override onlyProcessor isValidPayloadId(payloadId_) returns (bytes memory) {
        uint256 _payloadHeader = payloadHeader[payloadId_];
        bytes memory _payloadBody = payloadBody[payloadId_];

        if (payloadTracking[payloadId_] == PayloadState.PROCESSED) {
            revert Error.INVALID_PAYLOAD_STATE();
        }

        (, uint256 callbackType, , , , ) = _payloadHeader.decodeTxInfo();

        AMBMessage memory _message = AMBMessage(_payloadHeader, _payloadBody);

        if (callbackType == uint256(CallbackType.FAIL)) {
            ISuperPositions(superRegistry.superPositions()).stateSync(_message);
        }

        /// @dev validates quorum
        // v._proof = keccak256(abi.encode(v._message));

        // if (messageQuorum[v._proof] < getRequiredMessagingQuorum(v.srcChainId)) {
        //     revert Error.QUORUM_NOT_REACHED();
        // }

        /// @dev sets status as processed
        /// @dev check for re-entrancy & relocate if needed
        payloadTracking[payloadId_] = PayloadState.PROCESSED;

        return bytes("");
    }

    /*///////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice CoreStateRegistry-like function for build message back to the source. In regular flow called after xChainWithdraw succeds.
    /// @dev Constructs return message in case of a FAILURE to perform redemption of already unlocked assets
    function _constructSingleReturnData(
        address srcSender_,
        uint64 srcChainId_,
        uint256 payloadId_,
        InitSingleVaultData memory singleVaultData_
    ) internal view returns (bytes memory returnMessage) {
        /// @notice Send Data to Source to issue superform positions.
        return
            abi.encode(
                AMBMessage(
                    _packTxInfo(
                        uint8(TransactionType.WITHDRAW),
                        uint8(CallbackType.FAIL),
                        0,
                        STATE_REGISTRY_TYPE,
                        srcSender_,
                        srcChainId_
                    ),
                    abi.encode(ReturnSingleData(payloadId_, singleVaultData_.amount))
                )
            );
    }

    /// @notice In regular flow, BaseStateRegistry function for messaging back to the source
    /// @notice Use constructed earlier return message to send acknowledgment (msg) back to the source
    function _dispatchAcknowledgement(uint64 dstChainId_, bytes memory message_, bytes memory ackExtraData_) internal {
        AckAMBData memory ackData = abi.decode(ackExtraData_, (AckAMBData));
        uint8[] memory ambIds_ = ackData.ambIds;
        AMBExtraData memory d = abi.decode(ackData.extraData, (AMBExtraData));

        _dispatchPayload(msg.sender, ambIds_[0], dstChainId_, d.gasPerAMB[0], message_, d.extraDataPerAMB[0]);

        if (ambIds_.length > 1) {
            _dispatchProof(msg.sender, ambIds_, dstChainId_, d.gasPerAMB, message_, d.extraDataPerAMB);
        }
    }
}
