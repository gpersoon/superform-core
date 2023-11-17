// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.21;

import "./Abstract.Deploy.Single.s.sol";

import "forge-std/console.sol";

struct UpdateVars {
    uint64 chainId;
    uint64 dstChainId;
    address paymentHelper;
    address superRegistry;
}

abstract contract AbstractNewPaymentHelper is AbstractDeploySingle {
    function _newPaymentHelper(
        uint256 i,
        uint256 trueIndex,
        Cycle cycle,
        uint64[] memory targetDeploymentChains,
        uint64[] memory finalDeployedChains
    )
        internal
        setEnvDeploy(cycle)
    {
        UpdateVars memory vars;

        vars.chainId = targetDeploymentChains[i];
        vm.startBroadcast(deployerPrivateKey);

        console.log("i", i);
        vars.superRegistry = _readContract(chainNames[trueIndex], vars.chainId, "SuperRegistry");

        vars.paymentHelper = address(new PaymentHelper{salt: salt}(vars.superRegistry));

        console.log("paymentHelper", vars.paymentHelper);

        /// @dev configure payment helper
        PaymentHelper(payable(vars.paymentHelper)).updateRemoteChain(
            vars.chainId, 1, abi.encode(PRICE_FEEDS[vars.chainId][vars.chainId])
        );
        PaymentHelper(payable(vars.paymentHelper)).updateRemoteChain(vars.chainId, 8, abi.encode(50 * 10 ** 9 wei));
        PaymentHelper(payable(vars.paymentHelper)).updateRemoteChain(vars.chainId, 9, abi.encode(750));
        PaymentHelper(payable(vars.paymentHelper)).updateRemoteChain(vars.chainId, 10, abi.encode(40_000));
        PaymentHelper(payable(vars.paymentHelper)).updateRemoteChain(vars.chainId, 11, abi.encode(50_000));

        /// @dev Set all trusted remotes for each chain & configure amb chains ids
        for (uint256 j = 0; j < finalDeployedChains.length; j++) {
            if (j != i) {
                vars.dstChainId = finalDeployedChains[j];

                PaymentHelper(payable(vars.paymentHelper)).addRemoteChain(
                    vars.dstChainId,
                    IPaymentHelper.PaymentHelperConfig(
                        PRICE_FEEDS[vars.chainId][vars.dstChainId],
                        address(0),
                        50_000,
                        40_000,
                        70_000,
                        80_000,
                        12e8,
                        /// 12 usd
                        28 gwei,
                        10 wei,
                        10_000,
                        10_000
                    )
                );

                PaymentHelper(payable(vars.paymentHelper)).updateRegisterSERC20Params(0, generateBroadcastParams(5, 1));

                PaymentHelper(payable(vars.paymentHelper)).updateRemoteChain(vars.dstChainId, 9, abi.encode(750));
            }
        }
        vm.stopBroadcast();
    }
}
