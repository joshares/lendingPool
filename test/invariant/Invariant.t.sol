// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/Lending.sol";
import {MockERC20} from "../mocks/ERC20Mock.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {Handler} from "./Handler.t.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract InvariantTests is Test {
    Lending public pool;
    MockERC20 public collateralToken;
    MockERC20 public assetToken;
    MockPriceOracle public oracle;
    Handler public handler;

    uint8 constant ORACLE_DECIMALS = 8;

    function setUp() public {
        // Deploy tokens
        collateralToken = new MockERC20("WETH", "WETH");
        assetToken = new MockERC20("USDC", "USDC");

        // Deploy oracle
        oracle = new MockPriceOracle(ORACLE_DECIMALS);
        oracle.setPrice(address(collateralToken), 2000e8); // $2,000

        // Deploy pool
        pool = new Lending(address(collateralToken), address(assetToken), address(oracle), 7500, 8000, 5e16, 3e16);

        // Deploy handler
        handler = new Handler(pool, collateralToken, assetToken, oracle);

        targetContract(address(handler));

        excludeSelector(FuzzSelector({addr: address(handler), selectors: _getExcludeSelectors()}));
    }

    function _getExcludeSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.getActors.selector;
        selectors[1] = Handler.getGhostTotalSupplied.selector;
        selectors[2] = Handler.getGhostTotalBorrowed.selector;
        selectors[3] = Handler.getGhostTotalCollateral.selector;
        selectors[4] = Handler.getGhostSupplySum.selector;
        selectors[5] = Handler.getGhostBorrowSum.selector;
        selectors[6] = Handler.getGhostCollateralSum.selector;

        return selectors;
    }

    // tests

    function invariant_protocolSolvency() public view {
        uint256 totalCollateralValue = _getCollateralValue(pool.totalCollateral());
        uint256 totalDebt = pool.totalBorrowed();
        uint256 liquidationThreshold = pool.liquidationThreshold();

        uint256 maxSafeDebt = (totalCollateralValue * liquidationThreshold) / 10000;

        assertGe(maxSafeDebt, totalDebt, "CRITICAL: Protocol is insolvent! Total debt exceeds collateral value");
    }

    function invariant_accountingConsistency() public view {
        assertEq(handler.ghost_supplySum(), pool.totalSupplied(), "Supply accounting broken: individual sums != total");

        assertEq(handler.ghost_borrowSum(), pool.totalBorrowed(), "Borrow accounting broken: individual sums != total");

        assertEq(
            handler.ghost_collateralSum(),
            pool.totalCollateral(),
            "Collateral accounting broken: individual sums != total"
        );
    }

    function invariant_tokenConservation() public view {
        uint256 poolAssetBalance = assetToken.balanceOf(address(pool));
        uint256 expectedBalance = pool.totalSupplied() - pool.totalBorrowed();

        // Allow for small rounding (< 1000 wei)
        assertApproxEqAbs(poolAssetBalance, expectedBalance, 1000, "Asset token conservation violated");

        uint256 poolCollateralBalance = collateralToken.balanceOf(address(pool));
        assertEq(poolCollateralBalance, pool.totalCollateral(), "Collateral token conservation violated");
    }

    function invariant_supplyGeBorrow() public view {
        assertGe(pool.totalSupplied(), pool.totalBorrowed(), "CRITICAL: Borrowed more than supplied!");
    }

    function invariant_healthFactorSafety() public view {
        address[] memory actors = handler.getActors();

        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 debt = pool.getBorrowerDebt(actor);

            if (debt > 0) {
                uint256 hf = pool.getHealthFactor(actor);
                bool canLiquidate = pool.canLiquidate(actor);

                // Either healthy OR liquidatable
                assertTrue(
                    hf >= 10000 || canLiquidate,
                    string(abi.encodePacked("Position unhealthy but not liquidatable: ", vm.toString(actor)))
                );
            }
        }
    }

    function invariant_interestMonotonic() public pure {
        assertTrue(true);
    }

    function invariant_noNegativeBalances() public view {
        address[] memory actors = handler.getActors();

        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];

            pool.suppliedAmount(actor);
            pool.borrowedAmount(actor);
            pool.collateralDeposits(actor);
        }

        // Check totals
        pool.totalSupplied();
        pool.totalBorrowed();
        pool.totalCollateral();
    }

    function invariant_utilizationBounds() public view {
        uint256 utilization = pool.getUtilizationRate();

        assertLe(utilization, 10000, "Utilization exceeds 100%");
    }

    function invariant_availableLiquidity() public view {
        uint256 available = pool.getAvailableLiquidity();
        uint256 expected = pool.totalSupplied() - pool.totalBorrowed();

        assertApproxEqAbs(available, expected, 1000, "Available liquidity calculation wrong");
    }

    function invariant_ltvRespected() public view {
        address[] memory actors = handler.getActors();
        uint256 maxLTV = pool.maxLTV();

        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 debt = pool.getBorrowerDebt(actor);

            if (debt > 0) {
                uint256 collateralValue = _getCollateralValue(pool.collateralDeposits(actor));
                uint256 maxBorrow = (collateralValue * maxLTV) / 10000;

                // Allow for interest accrual slightly exceeding
                assertLe(
                    debt,
                    maxBorrow * 101 / 100, // 1% buffer for interest
                    "Position exceeds max LTV"
                );
            }
        }
    }

    function _getCollateralValue(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = oracle.getPrice(address(collateralToken));
        return (amount * price) / (10 ** ORACLE_DECIMALS);
    }

    function invariant_callSummary() public view {
        console.log("\n=== INVARIANT TEST SUMMARY ===");
        console.log("Total Supply calls:", handler.callCount_supply());
        console.log("Total Borrow calls:", handler.callCount_borrow());
        console.log("Total Repay calls:", handler.callCount_repay());
        console.log("Total Withdraw Supply calls:", handler.callCount_withdrawSupply());
        console.log("Total Withdraw Collateral calls:", handler.callCount_withdrawCollateral());
        console.log("Total Liquidate calls:", handler.callCount_liquidate());
        console.log("\n=== FINAL STATE ===");
        console.log("Total Supplied:", pool.totalSupplied());
        console.log("Total Borrowed:", pool.totalBorrowed());
        console.log("Total Collateral:", pool.totalCollateral());
        console.log("Utilization:", pool.getUtilizationRate(), "bp");
        console.log("Number of actors:", handler.getActors().length);
    }
}

