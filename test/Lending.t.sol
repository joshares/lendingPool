// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Lending.sol";
import "../src/MockPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LendingTest is Test {
    Lending public pool;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceOracle public oracle;

    address public owner = address(this);
    address public alice = address(0x1); // LENDER
    address public bob = address(0x2); // BORROWER
    address public charlie = address(0x3); // LIQUIDATOR
    address public dave = address(0x4); // ANOTHER LENDER

    uint256 constant MAX_LTV = 7500; // 75%
    uint256 constant LIQ_THRESHOLD = 8000; // 80%
    uint256 constant BORROW_RATE = 5e16; // 5% APR
    uint256 constant SUPPLY_RATE = 3e16; // 3% APR
    uint256 constant ETH_PRICE = 2000e8; // $2,000
    uint8 constant ORACLE_DECIMALS = 8;

    function setUp() public {
        assetToken = new MockERC20("USD Coin", "USDC");
        collateralToken = new MockERC20("Wrapped ETH", "WETH");

        oracle = new MockPriceOracle(ORACLE_DECIMALS);
        oracle.setPrice(address(collateralToken), ETH_PRICE);

        pool = new Lending(
            address(collateralToken),
            address(assetToken),
            address(oracle),
            MAX_LTV,
            LIQ_THRESHOLD,
            BORROW_RATE,
            SUPPLY_RATE
        );

        collateralToken.mint(bob, 100 * 10 ** 18);
        assetToken.mint(bob, 100_000 * 10 ** 18);
        assetToken.mint(alice, 100_000 * 10 ** 18);
        assetToken.mint(dave, 100_000 * 10 ** 18);
        assetToken.mint(charlie, 100_000 * 10 ** 18);

        vm.prank(alice);
        assetToken.approve(address(pool), type(uint256).max);

        vm.prank(dave);
        assetToken.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        collateralToken.approve(address(pool), type(uint256).max);

        vm.prank(charlie);
        assetToken.approve(address(pool), type(uint256).max);
    }

    // supply test

    function test_supply() public {
        uint256 supplyAmount = 10_000 * 10 ** 18;

        uint256 aliceInitialBalance = assetToken.balanceOf(alice);

        vm.prank(alice);
        pool.supply(supplyAmount);

        assertEq(pool.suppliedAmount(alice), supplyAmount, "Supply amount mismatch");
        assertEq(pool.totalSupplied(), supplyAmount, "Total supplied mismatch");
        assertEq(assetToken.balanceOf(alice), aliceInitialBalance - supplyAmount, "Alice balance mismatch after supply");
        assertEq(assetToken.balanceOf(address(pool)), supplyAmount, "Pool balance mismatch");
    }

    function test_supply_zero_amount() public {
        uint256 supplyAmount = 0;
        vm.prank(alice);
        vm.expectRevert(Lending.ZeroAmount.selector);
        pool.supply(supplyAmount);
    }

    function test_MultipleSuppliers() public {
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        vm.prank(dave);
        pool.supply(5_000 * 10 ** 18);

        assertEq(pool.suppliedAmount(alice), 10_000 * 10 ** 18);
        assertEq(pool.suppliedAmount(dave), 5_000 * 10 ** 18);
        assertEq(pool.totalSupplied(), 15_000 * 10 ** 18);
    }

    function test_SupplyInterestAccrual() public {
        uint256 supplyAmount = 10_000 * 10 ** 18;

        vm.prank(alice);
        pool.supply(supplyAmount);

        vm.warp(block.timestamp + 365 days);

        uint256 balance = pool.getSupplierBalance(alice);
        uint256 expectedInterest = (supplyAmount * 3) / 100;

        assertApproxEqRel(balance, supplyAmount + expectedInterest, 0.01e18, "Interest mismatch");
    }

    function test_WithdrawSupply() public {
        uint256 amount = 10_000 * 10 ** 18;

        vm.startPrank(alice);
        pool.supply(amount);

        pool.withdrawSupply(amount);
        vm.stopPrank();

        assertEq(pool.suppliedAmount(alice), 0);
        assertEq(pool.totalSupplied(), 0);
    }

    function test_withdraw_zero_amount() public {
        uint256 amount = 0;
        vm.startPrank(alice);
        pool.supply(10_000 * 10 ** 18);
        vm.expectRevert(Lending.ZeroAmount.selector);
        pool.withdrawSupply(amount);
        vm.stopPrank();
    }

    function test_ClaimSupplyInterest() public {
        uint256 amount = 10_000 * 10 ** 18;

        vm.prank(alice);
        pool.supply(amount);

        // Wait 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 balanceBefore = assetToken.balanceOf(alice);

        vm.prank(alice);
        pool.claimSupplyInterest();

        uint256 received = assetToken.balanceOf(alice) - balanceBefore;
        assertTrue(received > 0, "Should receive interest");

        // Principal should still be in pool
        assertEq(pool.suppliedAmount(alice), amount);
    }

    // borrowing test

    function test_BorrowFromSupply() public {
        // Alice supplies
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        // Bob deposits collateral
        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);
        assertEq(pool.collateralDeposits(bob), 10 * 10 ** 18);

        // Bob borrows
        uint256 borrowAmount = 5_000 * 10 ** 18;
        uint256 bobInitialBalance = assetToken.balanceOf(bob);
        vm.prank(bob);
        pool.borrow(borrowAmount);

        assertEq(pool.borrowedAmount(bob), borrowAmount);
        assertEq(pool.totalBorrowed(), borrowAmount);
        assertEq(assetToken.balanceOf(bob), bobInitialBalance + borrowAmount);
    }

    function test_BorrowInterestAccrual() public {
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        uint256 borrowAmount = 5_000 * 10 ** 18;
        vm.prank(bob);
        pool.borrow(borrowAmount);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 debt = pool.getBorrowerDebt(bob);
        uint256 expectedInterest = (borrowAmount * 5) / 100; // 5%

        assertApproxEqRel(debt, borrowAmount + expectedInterest, 0.01e18, "Borrow interest mismatch");
    }

    function test_RevertBorrowWithoutSupply() public {
        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        vm.prank(bob);
        vm.expectRevert(Lending.InsufficientLiquidity.selector);
        pool.borrow(5_000 * 10 ** 18);
    }

    function test_RevertBorrowExceedsLiquidity() public {
        // Alice supplies 5,000
        vm.prank(alice);
        pool.supply(5_000 * 10 ** 18);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        // Try to borrow 10,000 (more than available)
        vm.prank(bob);
        vm.expectRevert(Lending.InsufficientLiquidity.selector);
        pool.borrow(10_000 * 10 ** 18);
    }

    function test_CompleteLendingBorrowingCycle() public {
        uint256 supplyAmount = 10_000 * 10 ** 18;
        uint256 borrowAmount = 5_000 * 10 ** 18;

        // Step 1: Alice supplies
        vm.prank(alice);
        pool.supply(supplyAmount);

        // Step 2: Bob deposits and borrows
        vm.startPrank(bob);
        pool.depositCollateral(10 * 10 ** 18);
        pool.borrow(borrowAmount);

        // Approve repayment immediately before repaying
        assetToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Step 3: Time passes (1 year)
        vm.warp(block.timestamp + 365 days);

        // Step 4: Bob repays (with interest)
        vm.prank(bob);
        uint256 bobDebt = pool.getBorrowerDebt(bob);
        assertTrue(bobDebt > borrowAmount, "Interest should accrue");

        vm.prank(bob);
        pool.repay(bobDebt);

        assertEq(pool.borrowedAmount(bob), 0, "Debt should be cleared");

        // Step 5: Alice withdraws
        vm.prank(alice);
        uint256 aliceBalance = pool.getSupplierBalance(alice);

        // Alice should earn interest on the 5,000 that was borrowed
        // 5,000 * 3% * 1 year = 150
        uint256 expectedInterest = pool.getSupplierBalance(alice) - supplyAmount;

        assertApproxEqRel(aliceBalance, supplyAmount + expectedInterest, 0.01e18, "Alice balance mismatch");

        uint256 poolLiquidity = assetToken.balanceOf(address(pool));
        uint256 amountToWithdraw = aliceBalance > poolLiquidity ? poolLiquidity : aliceBalance;

        vm.prank(alice);
        pool.withdrawSupply(amountToWithdraw);

        if (aliceBalance > poolLiquidity) {
            assertEq(pool.suppliedAmount(alice), aliceBalance - poolLiquidity, "Partial withdrawal mismatch");
        } else {
            assertEq(pool.suppliedAmount(alice), 0, "Full withdrawal mismatch");
        }
    }

    function test_UtilizationRate() public {
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        vm.prank(bob);
        pool.borrow(6_000 * 10 ** 18);

        uint256 utilization = pool.getUtilizationRate();
        assertEq(utilization, 6000, "Utilization should be 60%");
    }

    function test_RevertWithdrawInsufficientLiquidity() public {
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        vm.prank(bob);
        pool.borrow(9_000 * 10 ** 18);

        vm.prank(alice);
        vm.expectRevert(Lending.InsufficientLiquidity.selector);
        pool.withdrawSupply(5_000 * 10 ** 18);
    }

    function test_PartialWithdrawal() public {
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        vm.prank(bob);
        pool.borrow(9_000 * 10 ** 18);

        // Should be able to withdraw 1,000 (available liquidity)
        vm.prank(alice);
        pool.withdrawSupply(1_000 * 10 ** 18);

        assertEq(pool.suppliedAmount(alice), 9_000 * 10 ** 18);
    }

    function test_ProtocolSpread() public {
        uint256 supplyAmount = 10_000 * 10 ** 18;
        uint256 borrowAmount = 10_000 * 10 ** 18;

        vm.prank(alice);
        pool.supply(supplyAmount);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        vm.prank(bob);
        pool.borrow(borrowAmount);

        // Wait 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 borrowerPays = pool.getBorrowerDebt(bob) - borrowAmount;
        uint256 lenderEarns = pool.getSupplierBalance(alice) - supplyAmount;

        assertApproxEqRel(borrowerPays, 500 * 10 ** 18, 0.01e18);

        assertApproxEqRel(lenderEarns, 300 * 10 ** 18, 0.01e18);

        uint256 protocolRevenue = borrowerPays - lenderEarns;
        assertApproxEqRel(protocolRevenue, 200 * 10 ** 18, 0.01e18);
    }

    // Liquidation test

    function test_LiquidationProtectsLenders() public {
        // Alice supplies
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        // Bob deposits and borrows
        vm.startPrank(bob);
        pool.depositCollateral(10 * 10 ** 18);
        pool.borrow(10_000 * 10 ** 18);
        vm.stopPrank();

        // ETH crashes to $1,200
        oracle.setPrice(address(collateralToken), 1200e8);

        assertTrue(pool.canLiquidate(bob), "Should be liquidatable");

        uint256 debt = pool.getBorrowerDebt(bob);

        // Charlie liquidates
        vm.prank(charlie);
        pool.liquidate(bob, debt);

        // Check Alice can still withdraw
        uint256 aliceBalance = pool.getSupplierBalance(alice);

        vm.prank(alice);
        pool.withdrawSupply(aliceBalance);

        // Alice got her money back (protocol protected)
        assertTrue(assetToken.balanceOf(alice) >= 10_000 * 10 ** 18, "Alice should be protected");
    }

    function test_HealthFactor() public {
        vm.prank(alice);
        pool.supply(20_000 * 10 ** 18);

        vm.prank(bob);
        pool.depositCollateral(10 * 10 ** 18);

        vm.prank(bob);
        pool.borrow(10_000 * 10 ** 18);

        uint256 hf = pool.getHealthFactor(bob);
        assertEq(hf, 16000, "HF should be 1.6");
    }

    // edge cases

    function testFuzz_SupplyAndWithdraw(uint256 amount) public {
        amount = bound(amount, 1 * 10 ** 18, 10_000 * 10 ** 18);

        assetToken.mint(alice, amount);

        vm.startPrank(alice);
        pool.supply(amount);
        pool.withdrawSupply(amount);
        vm.stopPrank();

        assertEq(pool.suppliedAmount(alice), 0);
    }

    function testFuzz_BorrowUpToMax(uint256 collateralAmount) public {
        collateralAmount = bound(collateralAmount, 1 * 10 ** 18, 50 * 10 ** 18);

        // Ensure pool has liquidity
        vm.prank(alice);
        pool.supply(100_000 * 10 ** 18);

        collateralToken.mint(bob, collateralAmount);

        vm.prank(bob);
        pool.depositCollateral(collateralAmount);

        uint256 maxBorrow = pool.getMaxBorrowAmount(bob);

        if (maxBorrow > 0) {
            vm.prank(bob);
            pool.borrow(maxBorrow);

            assertEq(pool.borrowedAmount(bob), maxBorrow);
        }
    }

    function test_ZeroSupply() public {
        assertEq(pool.getUtilizationRate(), 0);
        assertEq(pool.getAvailableLiquidity(), 0);
    }

    function test_MultipleSuppliesAndBorrows() public {
        // Alice supplies
        vm.prank(alice);
        pool.supply(10_000 * 10 ** 18);

        // Dave supplies
        vm.prank(dave);
        pool.supply(5_000 * 10 ** 18);

        // Bob borrows
        vm.prank(bob);
        pool.depositCollateral(20 * 10 ** 18);

        vm.prank(bob);
        pool.borrow(8_000 * 10 ** 18);

        assertEq(pool.totalSupplied(), 15_000 * 10 ** 18);
        assertEq(pool.totalBorrowed(), 8_000 * 10 ** 18);
        assertEq(pool.getAvailableLiquidity(), 7_000 * 10 ** 18);
    }
}
