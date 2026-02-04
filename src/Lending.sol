// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Lending is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  // constants
  uint256 private constant PERCENTAGE_FACTOR = 10000;
  uint256 private constant INTEREST_RATE_PRECISION = 1e18;
  uint256 private constant SECONDS_PER_YEAR = 365 days;
  uint256 private constant MIN_HEALTH_FACTOR = PERCENTAGE_FACTOR;
  uint256 private constant LIQUIDATION_BONUS = 500; // 5%

  // state variables
  IERC20 public immutable collateralToken;
  IERC20 public immutable assetToken;
  IPriceOracle public priceOracle;
  uint256 public maxLTV; 
  uint256 public liquidationThreshold;
  uint256 public borrowRate;
  uint256 public supplyRate;
  uint256 public totalSupplied;
  uint256 public totalBorrowed;
  uint256 public totalCollateral;

  mapping(address => uint256) public suppliedAmount;
  mapping(address => uint256) public lastSupplyAccrual;
  mapping(address => uint256) public accumulatedSupplyInterest;
  mapping(address => uint256) public collateralDeposits;
  mapping(address => uint256) public borrowedAmount;
  mapping(address => uint256) public lastBorrowAccrual;
  mapping(address => uint256) public accumulatedBorrowInterest;

  //  Events
    event AssetSupplied(address indexed user, uint256 amount);
    event AssetWithdrawn(address indexed user, uint256 amount, uint256 interestEarned);
    event SupplyInterestAccrued(address indexed user, uint256 interest);
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 totalDebt);
    event Repaid(address indexed user, uint256 amount, uint256 remainingDebt);
    event BorrowInterestAccrued(address indexed user, uint256 interest);
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 debtCovered,
        uint256 collateralSeized
    );

    // Errors
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientSupply();
    error BorrowExceedsLimit();
    error HealthFactorTooLow();
    error PositionHealthy();
    error NoDebt();
    error InsufficientLiquidity();




  constructor(
        address _collateralToken,
        address _assetToken,
        address _priceOracle,
        uint256 _maxLTV,
        uint256 _liquidationThreshold,
        uint256 _borrowRate,
        uint256 _supplyRate
  )Ownable(msg.sender) {
        require(_collateralToken != address(0), "Invalid collateral");
        require(_assetToken != address(0), "Invalid asset");
        require(_priceOracle != address(0), "Invalid oracle");
        require(_maxLTV < _liquidationThreshold, "LTV must be < threshold");
        require(_supplyRate < _borrowRate, "Supply rate must be < borrow rate");

        collateralToken = IERC20(_collateralToken);
        assetToken = IERC20(_assetToken);
        priceOracle = IPriceOracle(_priceOracle);
        maxLTV = _maxLTV;
        liquidationThreshold = _liquidationThreshold;
        borrowRate = _borrowRate;
        supplyRate = _supplyRate;
  }

  // lending/ supply functions

  function supply(uint256 amount)external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrueSupplyInterest(msg.sender);

        suppliedAmount[msg.sender] += amount;
        totalSupplied += amount;
        lastSupplyAccrual[msg.sender] = block.timestamp;

        assetToken.safeTransferFrom(msg.sender, address(this), amount);

        emit AssetSupplied(msg.sender, amount);
  }

    function withdrawSupply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueSupplyInterest(msg.sender);
        uint256 totalAmount = suppliedAmount[msg.sender] + accumulatedSupplyInterest[msg.sender];
        if (amount > totalAmount) revert InsufficientSupply();

        uint256 availableLiquidity = assetToken.balanceOf(address(this));
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        uint256 interestEarned = 0;

        if (amount <= accumulatedSupplyInterest[msg.sender]) {
            accumulatedSupplyInterest[msg.sender] -= amount;
            interestEarned = amount;
        } else {
            interestEarned = accumulatedSupplyInterest[msg.sender];
            uint256 principalPortion = amount - accumulatedSupplyInterest[msg.sender];
            accumulatedSupplyInterest[msg.sender] = 0;
            totalSupplied -= principalPortion;
            suppliedAmount[msg.sender] -= principalPortion;
            accumulatedSupplyInterest[msg.sender] = 0;
        }

        assetToken.safeTransfer(msg.sender, amount);
        emit AssetWithdrawn(msg.sender, amount, interestEarned);
        
  }

    function claimSupplyInterest() external nonReentrant {
        _accrueSupplyInterest(msg.sender);
        
        uint256 interest = accumulatedSupplyInterest[msg.sender];
        if (interest == 0) revert ZeroAmount();

        // Check liquidity
        uint256 available = assetToken.balanceOf(address(this));
        if (interest > available) revert InsufficientLiquidity();

        accumulatedSupplyInterest[msg.sender] = 0;
        
        assetToken.safeTransfer(msg.sender, interest);
        
        emit AssetWithdrawn(msg.sender, interest, interest);
    }

  //  collateral functions
  
    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        collateralDeposits[msg.sender] += amount;
        totalCollateral += amount;

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(msg.sender, amount);
    }
  
  
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (collateralDeposits[msg.sender] < amount) revert InsufficientCollateral();

        // Accrue borrow interest
        _accrueBorrowInterest(msg.sender);

        uint256 newCollateral = collateralDeposits[msg.sender] - amount;
        
        // Check health factor if user has debt
        if (borrowedAmount[msg.sender] > 0) {
            uint256 hf = _calculateHealthFactor(newCollateral, borrowedAmount[msg.sender]);
            if (hf < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();
        }

        collateralDeposits[msg.sender] = newCollateral;
        totalCollateral -= amount;

        collateralToken.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    // borrowing functions

     function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (collateralDeposits[msg.sender] == 0) revert InsufficientCollateral();

        // Accrue existing interest
        _accrueBorrowInterest(msg.sender);

        // Calculate max borrowable
        uint256 collateralValue = _getCollateralValue(collateralDeposits[msg.sender]);
        uint256 maxBorrow = (collateralValue * maxLTV) / PERCENTAGE_FACTOR;
        
        uint256 newTotalDebt = borrowedAmount[msg.sender] + amount;
        if (newTotalDebt > maxBorrow) revert BorrowExceedsLimit();

        // Check pool liquidity
        uint256 available = assetToken.balanceOf(address(this));
        if (amount > available) revert InsufficientLiquidity();

        // Update state
        borrowedAmount[msg.sender] = newTotalDebt;
        totalBorrowed += amount;
        lastBorrowAccrual[msg.sender] = block.timestamp;

        // Transfer borrowed assets
        assetToken.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, newTotalDebt);
    }
      
     function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (borrowedAmount[msg.sender] == 0) revert NoDebt();

        _accrueBorrowInterest(msg.sender);

        uint256 debt = borrowedAmount[msg.sender];
        uint256 repayAmount = amount > debt ? debt : amount;

        borrowedAmount[msg.sender] = debt - repayAmount;
        totalBorrowed -= repayAmount;

        if (borrowedAmount[msg.sender] == 0) {
            lastBorrowAccrual[msg.sender] = 0;
        }

        assetToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repaid(msg.sender, repayAmount, borrowedAmount[msg.sender]);
    }

  // liquidation functions

     function liquidate(address borrower, uint256 debtToCover) external nonReentrant {
        if (debtToCover == 0) revert ZeroAmount();

        _accrueBorrowInterest(borrower);

        uint256 hf = _calculateHealthFactor(
            collateralDeposits[borrower],
            borrowedAmount[borrower]
        );
        
        if (hf >= MIN_HEALTH_FACTOR) revert PositionHealthy();

        uint256 debt = borrowedAmount[borrower];
        uint256 actualDebt = debtToCover > debt ? debt : debtToCover;

        uint256 collateralPrice = priceOracle.getPrice(address(collateralToken));
        uint8 oracleDecimals = priceOracle.decimals();
        uint256 collateralToSeize = _calculateCollateralToSeize(actualDebt, collateralPrice, oracleDecimals);

        if (collateralToSeize > collateralDeposits[borrower]) {
            collateralToSeize = collateralDeposits[borrower];
        }

        // Update state
        borrowedAmount[borrower] -= actualDebt;
        collateralDeposits[borrower] -= collateralToSeize;
        totalBorrowed -= actualDebt;
        totalCollateral -= collateralToSeize;

        if (borrowedAmount[borrower] == 0) {
            lastBorrowAccrual[borrower] = 0;
        }

        // Transfers
        assetToken.safeTransferFrom(msg.sender, address(this), actualDebt);
        collateralToken.safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(borrower, msg.sender, actualDebt, collateralToSeize);
    }

    //view functions

    function getSupplierBalance(address user) external view returns (uint256) {
        uint256 interest = _calculatePendingSupplyInterest(user);
        return suppliedAmount[user] + accumulatedSupplyInterest[user] + interest;
    }

     function getBorrowerDebt(address user) external view returns (uint256) {
        return _getCurrentDebt(user);
    }

    function canLiquidate(address borrower) external view returns (bool) {
    uint256 debt = _getCurrentDebt(borrower);
    if (debt == 0) return false;

    uint256 hf = _calculateHealthFactor(
        collateralDeposits[borrower],
        debt
    );

    return hf < MIN_HEALTH_FACTOR;
}

    function getUtilizationRate() external view returns (uint256) {
        if (totalSupplied == 0) return 0;
        return (totalBorrowed * PERCENTAGE_FACTOR) / totalSupplied;
    }

     function getAvailableLiquidity() external view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function getHealthFactor(address user) external view returns (uint256) {
        uint256 debt = _getCurrentDebt(user);
        if (debt == 0) return type(uint256).max;
        return _calculateHealthFactor(collateralDeposits[user], debt);
    }

    function getMaxBorrowAmount(address user) external view returns (uint256) {
        uint256 collateralValue = _getCollateralValue(collateralDeposits[user]);
        uint256 maxBorrow = (collateralValue * maxLTV) / PERCENTAGE_FACTOR;
        uint256 currentDebt = _getCurrentDebt(user);
        return maxBorrow > currentDebt ? maxBorrow - currentDebt : 0;
    }

  
  // internal functions

    function _accrueSupplyInterest(address user) internal {
        uint256 supplied = suppliedAmount[user];
        if (supplied == 0) return;

        uint256 lastAccrual = lastSupplyAccrual[user];
        if (lastAccrual == 0) {
            lastSupplyAccrual[user] = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastAccrual;
        if (timeElapsed == 0) return;

        uint256 interest = (supplied * supplyRate * timeElapsed) / 
                          (INTEREST_RATE_PRECISION * SECONDS_PER_YEAR);

        if (interest > 0) {
            accumulatedSupplyInterest[user] += interest;
            emit SupplyInterestAccrued(user, interest);
        }

        lastSupplyAccrual[user] = block.timestamp;
    }

     function _calculatePendingSupplyInterest(address user) internal view returns (uint256) {
        uint256 supplied = suppliedAmount[user];
        if (supplied == 0) return 0;

        uint256 lastAccrual = lastSupplyAccrual[user];
        if (lastAccrual == 0 || lastAccrual == block.timestamp) return 0;

        uint256 timeElapsed = block.timestamp - lastAccrual;
        return (supplied * supplyRate * timeElapsed) / 
               (INTEREST_RATE_PRECISION * SECONDS_PER_YEAR);
    }
    
    function _accrueBorrowInterest(address user) internal {
        uint256 borrowed = borrowedAmount[user];
        if (borrowed == 0) return;

        uint256 lastAccrual = lastBorrowAccrual[user];
        if (lastAccrual == 0) {
            lastBorrowAccrual[user] = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastAccrual;
        if (timeElapsed == 0) return;

        uint256 interest = (borrowed * borrowRate * timeElapsed) / 
                          (INTEREST_RATE_PRECISION * SECONDS_PER_YEAR);

        if (interest > 0) {
            borrowedAmount[user] += interest;
            totalBorrowed += interest;
            emit BorrowInterestAccrued(user, interest);
        }

        lastBorrowAccrual[user] = block.timestamp;
    }

    function _getCurrentDebt(address user) internal view returns (uint256) {
        uint256 borrowed = borrowedAmount[user];
        if (borrowed == 0) return 0;

        uint256 lastAccrual = lastBorrowAccrual[user];
        if (lastAccrual == 0 || lastAccrual == block.timestamp) return borrowed;

        uint256 timeElapsed = block.timestamp - lastAccrual;
        uint256 interest = (borrowed * borrowRate * timeElapsed) / 
                          (INTEREST_RATE_PRECISION * SECONDS_PER_YEAR);

        return borrowed + interest;
    }

    

    function _calculateHealthFactor(uint256 collateralAmount, uint256 borrowed) 
    internal 
    view 
    returns (uint256) 
{
    if (borrowed == 0) return type(uint256).max;

    uint256 collateralValue = _getCollateralValue(collateralAmount); 
    uint256 adjustedCollateral = (collateralValue * liquidationThreshold) / PERCENTAGE_FACTOR; 

    uint256 HF = (adjustedCollateral * PERCENTAGE_FACTOR) / borrowed; // returns in 1e4 units

    return HF;
}

    function _getCollateralValue(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = priceOracle.getPrice(address(collateralToken));
        require(price > 0, "Invalid oracle price");
        uint8 oracleDecimals = priceOracle.decimals();
        return (amount * price) / (10 ** oracleDecimals);
    }

    function _calculateCollateralToSeize(uint256 debtToCover, uint256 collateralPrice, uint8 oracleDecimals) 
        internal 
        pure 
        returns (uint256) 
    {
        uint256 bonusMultiplier = PERCENTAGE_FACTOR + LIQUIDATION_BONUS;
        uint256 valueToSeize = (debtToCover * bonusMultiplier) / PERCENTAGE_FACTOR;
        return (valueToSeize * (10 ** oracleDecimals)) / collateralPrice;
    }

    // admin funtion

     function setBorrowRate(uint256 newRate) external onlyOwner {
        borrowRate = newRate;
    }

    function setSupplyRate(uint256 newRate) external onlyOwner {
        require(newRate < borrowRate, "Supply rate must be < borrow rate");
        supplyRate = newRate;
    }

    function setMaxLTV(uint256 newLTV) external onlyOwner {
        require(newLTV < liquidationThreshold, "LTV must be < threshold");
        maxLTV = newLTV;
    }

    function setLiquidationThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > maxLTV, "Threshold must be > LTV");
        liquidationThreshold = newThreshold;
    }



}

interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256);
     function decimals() external view returns (uint8);
}