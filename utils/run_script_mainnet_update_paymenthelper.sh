#!/usr/bin/env bash

# Read the RPC URL
source .env


# Run the script

echo Running Update PaymentHelper: ...


FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 0 --rpc-url $BSC_RPC_URL --broadcast --slow --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

wait

FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 1 --rpc-url $POLYGON_RPC_URL --broadcast --slow --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

wait

FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 2 --rpc-url $AVALANCHE_RPC_URL --broadcast --slow --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92
