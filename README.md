# Lending Protocol - Aave-Style DeFi Lending

Production-grade lending protocol for decentralized borrowing and lending.

## 📚 Start Here

**Read in this order:**
1. **[CONCEPTS.md](CONCEPTS.md)** (30 min) ← START HERE!
2. **[src/LendingPool.sol](src/LendingPool.sol)** (45 min)
3. **[test/LendingPool.t.sol](test/LendingPool.t.sol)** (30 min)

## 🎯 What This Does

A simplified Aave-style lending protocol where:
- **Lenders** deposit assets → earn interest
- **Borrowers** lock collateral → borrow assets
- **Liquidators** repay bad debt → earn profit

## ✨ Features

### Core Functionality
- ✅ Deposit collateral (over-collateralized)
- ✅ Borrow against collateral
- ✅ Repay loans with interest
- ✅ Withdraw collateral (if safe)
- ✅ Automated liquidations

### Financial Mechanics
- ✅ **LTV (Loan-to-Value)**: 75% maximum
- ✅ **Liquidation Threshold**: 80%
- ✅ **Health Factor**: Real-time risk monitoring
- ✅ **Interest**: Simple interest per second
- ✅ **Liquidation Bonus**: 5% incentive

### Security
- ✅ Reentrancy protection
- ✅ Safe token transfers
- ✅ Precise math (no rounding errors)
- ✅ Over-collateralization enforced
- ✅ Health factor checks

## 🧮 The Math (Explained Simply)

### 1. Loan-to-Value (LTV)

**What you can borrow vs what you deposit:**

```
LTV = (Amount Borrowed / Collateral Value) × 100%
```

**Example:**
```
Deposit: 10 ETH @ $2,000 = $20,000
Max LTV: 75%
Max Borrow: $20,000 × 0.75 = $15,000

You borrow $10,000:
Your LTV = ($10,000 / $20,000) × 100% = 50% ✓ Safe
```

### 2. Health Factor

**How safe is your loan:**

```
Health Factor = (Collateral × Liquidation Threshold) / Borrowed

HF > 1.0 = Safe ✓
HF = 1.0 = At risk ⚠️
HF < 1.0 = Liquidation! ❌
```

**Example:**
```
Collateral: $20,000
Liquidation Threshold: 80%
Borrowed: $10,000

HF = ($20,000 × 0.80) / $10,000 = 1.6 ✓ Healthy!

If ETH drops to $1,500:
HF = ($15,000 × 0.80) / $10,000 = 1.2 ✓ Still safe

If ETH drops to $1,200:
HF = ($12,000 × 0.80) / $10,000 = 0.96 ❌ LIQUIDATION!
```

### 3. Interest Calculation

**Simple interest per second:**

```
Interest = Principal × Rate × (Time / Year)
```

**Example:**
```
Borrow: $10,000
Rate: 5% APR
Time: 1 year

Interest = $10,000 × 0.05 × 1 = $500
Total Owed: $10,500

For 30 days:
Interest = $10,000 × 0.05 × (30/365) = $41.10
```

**In Solidity:**
```solidity
interest = (principal * rate * timeElapsed) / (PRECISION * SECONDS_PER_YEAR)
```

### 4. Liquidation Math

**When HF < 1.0, liquidators step in:**

```
Collateral to Seize = (Debt × (1 + Bonus)) / Collateral Price
```

**Example:**
```
User's debt: $10,000
Liquidation bonus: 5%
ETH price: $1,200

Amount with bonus: $10,000 × 1.05 = $10,500
ETH to seize: $10,500 / $1,200 = 8.75 ETH

Liquidator:
- Pays: $10,000
- Gets: 8.75 ETH worth $10,500
- Profit: $500 ✓
```

## 🚀 Quick Start

### Install & Test

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install

# Run tests
forge test

# Run with details
forge test -vvv

# Run specific test
forge test --match-test test_Liquidation -vvvv
```

### Expected Output

```
Running 20+ tests for test/LendingPool.t.sol:LendingPoolTest
[PASS] test_DepositCollateral() (gas: 141234)
[PASS] test_Borrow() (gas: 182043)
[PASS] test_HealthFactor() (gas: 165432)
[PASS] test_Liquidation() (gas: 234567)
...
Test result: ok. 20 passed; 0 failed
```

## 📖 Complete Example

### Scenario: Alice Borrows and Gets Liquidated

```solidity
// STEP 1: Alice deposits 10 ETH ($2,000 each)
alice.depositCollateral(10 ETH);
// Collateral value: $20,000

// STEP 2: Alice borrows $10,000 USDC
alice.borrow($10,000);
// LTV: 50%
// Health Factor: 1.6 ✓

// STEP 3: Time passes, interest accrues
// After 30 days: $41 interest
// Total debt: $10,041

// STEP 4: ETH price crashes to $1,250
// Collateral value: $12,500
// Health Factor: ($12,500 × 0.80) / $10,041 = 0.99 ⚠️

// STEP 5: ETH drops more to $1,200
// Health Factor: 0.96 ❌ LIQUIDATION!

// STEP 6: Liquidator acts
liquidator.liquidate(alice, $10,041);
// Liquidator pays: $10,041
// Liquidator gets: 8.77 ETH ($10,524 worth)
// Liquidator profit: $483

// Result:
// - Alice loses 8.77 ETH
// - Alice keeps 1.23 ETH
// - Alice's debt cleared
// - Liquidator profits $483
```

## 🔧 How to Use

### As a Borrower

```solidity
// 1. Approve collateral
collateralToken.approve(lendingPool, amount);

// 2. Deposit collateral
lendingPool.depositCollateral(10 ether);

// 3. Check max borrow
uint256 maxBorrow = lendingPool.getMaxBorrowAmount(msg.sender);

// 4. Borrow (safely under max)
lendingPool.borrow(maxBorrow * 80 / 100); // Borrow 80% of max

// 5. Monitor health factor
uint256 hf = lendingPool.getHealthFactor(msg.sender);
// Keep HF > 1.2 for safety!

// 6. Repay when ready
borrowToken.approve(lendingPool, amount);
lendingPool.repay(amount);

// 7. Withdraw collateral
lendingPool.withdrawCollateral(amount);
```

### As a Liquidator

```solidity
// 1. Find unhealthy positions
bool canLiquidate = lendingPool.canLiquidate(user);

if (canLiquidate) {
    // 2. Approve repayment
    uint256 debt = lendingPool.getCurrentDebt(user);
    borrowToken.approve(lendingPool, debt);
    
    // 3. Liquidate
    lendingPool.liquidate(user, debt);
    
    // 4. Profit! You received collateral worth debt + 5%
}
```

## 📊 Key Parameters

```
Maximum LTV:           75%  (can borrow up to 75% of collateral value)
Liquidation Threshold: 80%  (liquidated at 80%)
Safety Buffer:         5%   (difference between LTV and threshold)
Interest Rate:         5%   APR (adjustable)
Liquidation Bonus:     5%   (liquidator profit incentive)
```

## 🔒 Security Features

### 1. Over-Collateralization

**Problem:** No credit checks in DeFi
**Solution:** Require 133% collateral (for 75% LTV)

```
Want to borrow $100?
Must deposit $133+ worth of collateral
```

### 2. Health Factor Monitoring

**Real-time risk assessment:**
```
HF > 1.5 = Very safe
HF 1.2-1.5 = Moderate risk
HF 1.0-1.2 = High risk
HF < 1.0 = Liquidation
```

### 3. Automated Liquidations

**Prevents protocol insolvency:**
- Bot monitors all positions
- When HF < 1.0, liquidate
- Liquidator gets 5% bonus
- Protocol stays solvent

### 4. Reentrancy Protection

```solidity
function withdraw() external nonReentrant {
    // State updated before transfer
    collateralDeposits[msg.sender] = 0;
    token.transfer(msg.sender, amount);
}
```

### 5. Precision Math

```solidity
// Multiply before divide to avoid rounding
interest = (principal * rate * time) / (PRECISION * SECONDS_PER_YEAR);
```

## ⚠️ Known Limitations

### What This DOESN'T Have (Yet)

- ❌ Multiple collateral types
- ❌ Multiple borrow assets
- ❌ Variable interest rates
- ❌ Compound interest
- ❌ Flash loans
- ❌ Isolated positions
- ❌ Chainlink price feeds (uses mock)

### For Production, Add:

1. **Real Price Oracles** (Chainlink)
2. **Multiple Assets** (different LTVs per asset)
3. **Interest Rate Models** (based on utilization)
4. **Governance** (parameter updates)
5. **Insurance Fund** (to cover bad debt)
6. **Emergency Pause** (for bugs)

## 🧪 Testing

### Test Categories

```bash
# Basic operations
forge test --match-test test_Deposit
forge test --match-test test_Borrow
forge test --match-test test_Repay

# Health & Liquidation
forge test --match-test test_HealthFactor
forge test --match-test test_Liquidation

# Interest
forge test --match-test test_Interest

# Edge cases
forge test --match-test testFuzz
```

### Coverage

Run coverage report:
```bash
forge coverage
```

Expected: >90% coverage

## 📈 Deployment

### Testnet Deployment

```bash
# 1. Set up environment
cp .env.example .env
nano .env  # Add your keys

# 2. Deploy
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

### Constructor Parameters

```solidity
constructor(
    address collateralToken,    // WETH address
    address borrowToken,         // USDC address
    address priceOracle,        // Chainlink oracle
    uint256 maxLTV,             // 7500 (75%)
    uint256 liquidationThreshold, // 8000 (80%)
    uint256 interestRate        // 5e16 (5% APR)
)
```

## 🎓 Learning Objectives

After completing this, you should understand:

1. **Over-collateralization**
   - Why it's needed
   - How to calculate LTV
   - Safety buffers

2. **Health Factor**
   - What it measures
   - How it's calculated
   - When liquidation occurs

3. **Interest Mechanics**
   - Simple vs compound
   - Per-second accrual
   - Precision handling

4. **Liquidations**
   - Why they exist
   - How liquidators profit
   - Protocol protection

5. **DeFi Math**
   - Percentage calculations
   - Precision scaling
   - Division order

## 🔗 Related Protocols

This is inspired by:
- **Aave** - Multi-asset lending
- **Compound** - Algorithmic money markets
- **MakerDAO** - CDP-based lending

## 📝 TODO for Production

- [ ] Add Chainlink price feeds
- [ ] Multiple collateral types
- [ ] Variable interest rates
- [ ] Compound interest
- [ ] Flash loans
- [ ] Governance
- [ ] Emergency pause
- [ ] Insurance fund
- [ ] Professional audit

## ⚠️ Disclaimer

Educational purposes only. NOT audited. Do NOT use in production without:
1. Professional security audit
2. Extensive testing
3. Real price oracles
4. Insurance mechanisms

## 📄 License

MIT

---

## Quick Reference Card

```
┌─────────────────────────────────────────┐
│ LTV: How much you can borrow           │
│ Formula: Borrowed / Collateral         │
│ Max: 75%                                │
├─────────────────────────────────────────┤
│ Health Factor: How safe you are        │
│ Formula: (Collateral × 0.80) / Borrowed│
│ Safe: > 1.0                             │
├─────────────────────────────────────────┤
│ Interest: What you pay to borrow       │
│ Formula: Principal × Rate × Time       │
│ Rate: 5% APR                            │
├─────────────────────────────────────────┤
│ Liquidation: Emergency sale            │
│ When: Health Factor < 1.0              │
│ Bonus: +5% to liquidator               │
└─────────────────────────────────────────┘
```

---

**Ready to learn? Start with [CONCEPTS.md](CONCEPTS.md)!** 🚀
