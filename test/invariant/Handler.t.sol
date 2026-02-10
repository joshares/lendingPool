// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/Lending.sol";
import "../mocks/MockPriceOracle.sol";
import {MockERC20} from "../mocks/ERC20Mock.sol";

contract Handler is Test {
    Lending pool;
    MockERC20 public collateralToken;
    MockERC20 public assetToken;
    MockPriceOracle public oracle;

    // Track all actors (users) that interact with protocol
    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost variables for tracking
    uint256 public ghost_totalSupplied;
    uint256 public ghost_totalBorrowed;
    uint256 public ghost_totalCollateral;
    uint256 public ghost_supplySum;
    uint256 public ghost_borrowSum;
    uint256 public ghost_collateralSum;

    // Call counters for debugging
    uint256 public callCount_supply;
    uint256 public callCount_borrow;
    uint256 public callCount_repay;
    uint256 public callCount_withdrawSupply;
    uint256 public callCount_withdrawCollateral;
    uint256 public callCount_liquidate;

    // Price bounds for realistic testing
    uint256 public constant MIN_ETH_PRICE = 1000e8; // $1,000
    uint256 public constant MAX_ETH_PRICE = 5000e8; // $5,000

    constructor(Lending _pool, MockERC20 _collateral, MockERC20 _asset, MockPriceOracle _oracle) {
        pool = _pool;
        collateralToken = _collateral;
        assetToken = _asset;
        oracle = _oracle;
    }

    // MODIFIERS

    modifier useActor(uint256 actorSeed) {
        address actor = _getActor(actorSeed);
        vm.startPrank(actor);
        _;
        vm.stopPrank();
        _updateGhostVariables();
    }

    modifier countCall(string memory name) {
        if (keccak256(bytes(name)) == keccak256("supply")) callCount_supply++;
        else if (keccak256(bytes(name)) == keccak256("borrow")) callCount_borrow++;
        else if (keccak256(bytes(name)) == keccak256("repay")) callCount_repay++;
        else if (keccak256(bytes(name)) == keccak256("withdrawSupply")) callCount_withdrawSupply++;
        else if (keccak256(bytes(name)) == keccak256("withdrawCollateral")) callCount_withdrawCollateral++;
        else if (keccak256(bytes(name)) == keccak256("liquidate")) callCount_liquidate++;
        _;
    }

    function _getActor(uint256 seed) internal returns (address) {
        uint256 index = seed % 10; // 10 different actors
        address actor = address(uint160(0x1000 + index));

        if (!isActor[actor]) {
            actors.push(actor);
            isActor[actor] = true;

            // Give actor tokens
            collateralToken.mint(actor, 1000 ether);
            assetToken.mint(actor, 1_000_000e18);

            // Approve pool
            vm.startPrank(actor);
            collateralToken.approve(address(pool), type(uint256).max);
            assetToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        return actor;
    }

    function _updateGhostVariables() internal {
        ghost_totalSupplied = pool.totalSupplied();
        ghost_totalBorrowed = pool.totalBorrowed();
        ghost_totalCollateral = pool.totalCollateral();

        // Recalculate sums
        ghost_supplySum = 0;
        ghost_borrowSum = 0;
        ghost_collateralSum = 0;

        for (uint256 i = 0; i < actors.length; i++) {
            ghost_supplySum += pool.suppliedAmount(actors[i]);
            ghost_borrowSum += pool.borrowedAmount(actors[i]);
            ghost_collateralSum += pool.collateralDeposits(actors[i]);
        }
    }

    // view selectors

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function getGhostTotalSupplied() external view returns (uint256) {
        return ghost_totalSupplied;
    }

    function getGhostTotalBorrowed() external view returns (uint256) {
        return ghost_totalBorrowed;
    }

    function getGhostTotalCollateral() external view returns (uint256) {
        return ghost_totalCollateral;
    }

    function getGhostSupplySum() external view returns (uint256) {
        return ghost_supplySum;
    }

    function getGhostBorrowSum() external view returns (uint256) {
        return ghost_borrowSum;
    }

    function getGhostCollateralSum() external view returns (uint256) {
        return ghost_collateralSum;
    }

    // HANDLER FUNCTIONS

    function supply(uint256 actorSeed, uint256 amount) external useActor(actorSeed) countCall("supply") {
        // Bound to reasonable range
        amount = bound(amount, 1e18, 100_000e18);

        // Check actor has enough
        if (assetToken.balanceOf(msg.sender) < amount) return;

        try pool.supply(amount) {
        // Success
        }
            catch {
            // Expected failures are ok
        }
    }

    function depositCollateral(uint256 actorSeed, uint256 amount)
        external
        useActor(actorSeed)
        countCall("depositCollateral")
    {
        amount = bound(amount, 1 ether, 100 ether);

        if (collateralToken.balanceOf(msg.sender) < amount) return;

        try pool.depositCollateral(amount) {
        // Success
        }
            catch {
            // Expected failures ok
        }
    }

    function borrow(uint256 actorSeed, uint256 amount) external useActor(actorSeed) countCall("borrow") {
        amount = bound(amount, 1e18, 50_000e18);

        // Only borrow if have collateral
        if (pool.collateralDeposits(msg.sender) == 0) return;

        try pool.borrow(amount) {
        // Success
        }
            catch {
            // Expected failures (exceeds LTV, no liquidity, etc.)
        }
    }

    function repay(uint256 actorSeed, uint256 amount) external useActor(actorSeed) countCall("repay") {
        uint256 debt = pool.getBorrowerDebt(msg.sender);
        if (debt == 0) return;

        amount = bound(amount, 1e18, debt);

        if (assetToken.balanceOf(msg.sender) < amount) return;

        try pool.repay(amount) {
        // Success
        }
            catch {
            // Unexpected
        }
    }

    function withdrawSupply(uint256 actorSeed, uint256 amount)
        external
        useActor(actorSeed)
        countCall("withdrawSupply")
    {
        uint256 balance = pool.getSupplierBalance(msg.sender);
        if (balance == 0) return;

        amount = bound(amount, 1e18, balance);

        try pool.withdrawSupply(amount) {
        // Success
        }
            catch {
            // Expected if insufficient liquidity
        }
    }

    function withdrawCollateral(uint256 actorSeed, uint256 amount)
        external
        useActor(actorSeed)
        countCall("withdrawCollateral")
    {
        uint256 collateral = pool.collateralDeposits(msg.sender);
        if (collateral == 0) return;

        amount = bound(amount, 1 ether, collateral);

        try pool.withdrawCollateral(amount) {
        // Success
        }
            catch {
            // Expected if breaks health factor
        }
    }

    function changePrice(uint256 newPrice) external {
        newPrice = bound(newPrice, MIN_ETH_PRICE, MAX_ETH_PRICE);
        oracle.setPrice(address(collateralToken), newPrice);
        _updateGhostVariables();
    }

    function liquidate(uint256 actorSeed, uint256 targetSeed) external useActor(actorSeed) countCall("liquidate") {
        address target = _getActor(targetSeed);

        // Check if target is liquidatable
        if (!pool.canLiquidate(target)) return;

        uint256 debt = pool.getBorrowerDebt(target);
        if (debt == 0) return;

        // Liquidator needs funds
        if (assetToken.balanceOf(msg.sender) < debt) return;

        try pool.liquidate(target, debt) {
        // Success
        }
            catch {
            // Unexpected
        }
    }

    function warpTime(uint256 timeSkip) external {
        timeSkip = bound(timeSkip, 1, 365 days);
        vm.warp(block.timestamp + timeSkip);
        _updateGhostVariables();
    }
}
