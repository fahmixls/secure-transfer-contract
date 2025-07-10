// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {SecureTransfer} from "../src/SecureTransfer.sol";
import {console} from "forge-std/console.sol";

contract DeploySecureTransferLink is Script {
    // Default configuration - will be overridden by .env
    address public feeCollector = 0x0000000000000000000000000000000000000000;
    uint16 public feeBps = 100; // 1%
    uint256 public fixedFee = 100000; // 0.1 USDC (6 decimals)
    bool public deployMockToken = false;

    function run()
        external
        returns (address stlAddress, address mockTokenAddress)
    {
        // Read environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        feeCollector = vm.envOr("FEE_COLLECTOR", feeCollector);
        feeBps = uint16(vm.envOr("FEE_BPS", uint256(feeBps)));
        fixedFee = vm.envOr("FIXED_FEE", fixedFee);
        deployMockToken = vm.envOr("DEPLOY_MOCK_TOKEN", deployMockToken);

        // Default to deployer if fee collector not set
        if (feeCollector == address(0)) {
            feeCollector = vm.addr(deployerPrivateKey);
        }

        vm.startBroadcast(deployerPrivateKey);

        // Deploy main contract
        SecureTransfer secureTransfer = new SecureTransfer(
            feeCollector,
            feeBps,
            fixedFee
        );
        stlAddress = address(secureTransfer);

        // If we deployed mock token, auto-support it
        if (deployMockToken) {
            secureTransfer.setTokenSupport(mockTokenAddress, true);
        }

        vm.stopBroadcast();

        console.log("SecureTransferLink deployed at:", stlAddress);
        console.log("Fee Collector:", feeCollector);
        console.log(
            "Fee Configuration: %d bps + %d base fee",
            feeBps,
            fixedFee
        );

        return (stlAddress, mockTokenAddress);
    }
}
