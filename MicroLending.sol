// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MicroLending
 * @author Sibi Chakravarthi
 * @notice A fully self-contained, pedagogical DeFi micro-lending protocol.
 *
 * @dev DESIGN PHILOSOPHY (Teaching Notes)
 * ─────────────────────────────────────────────────────────────────────
 * This contract is intentionally self-contained for Sepolia testnet demos.
 * Instead of integrating a real ERC-20 stablecoin (e.g. USDC), the contract
 * manages an internal "mock USD" balance mapping. This means students can
 * test every function — borrow, repay, liquidate — without needing any
 * external tokens or oracle infrastructure.
 *
 * In a production protocol (Aave, Compound), you would replace:
 *   - mockUsdBalance  →  IERC20(stablecoin).transfer()
 *   - ETH_PRICE_USD   →  AggregatorV3Interface(chainlinkFeed).latestRoundData()
 *
 * CONTRACT LIFECYCLE:
 *   1. depositCollateral()   — Lock ETH, receive borrowing power
 *   2. borrow()              — Draw down mock USD against collateral
 *   3. repayLoan()           — Return mock USD + accrued interest
 *   4. withdrawCollateral()  — Reclaim ETH (only when no active loan)
 *   5. liquidate()           — Anyone can close an unhealthy position
 * ─────────────────────────────────────────────────────────────────────
 */
contract MicroLending {

    // ═══════════════════════════════════════════════════════════════════
    // PROTOCOL PARAMETERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Mock ETH price in USD — hardcoded for testnet.
    /// In production, replace with: AggregatorV3Interface(priceFeed).latestRoundData()
    uint256 public constant ETH_PRICE_USD = 3000;

    /// @notice Maximum Loan-to-Value ratio (50%).
    /// Borrower can draw up to 50% of their collateral's USD value.
    uint256 public constant LTV_PERCENTAGE = 50;

    /// @notice Liquidation threshold (75%).
    /// If a borrower's LTV exceeds this, their position can be liquidated.
    /// The gap between LTV_PERCENTAGE (50%) and this threshold (75%) is the
    /// "safety buffer" — it gives borrowers time to react before liquidation.
    uint256 public constant LIQUIDATION_THRESHOLD = 75;

    /// @notice Annual interest rate (5%), applied as a flat fee at borrow time.
    /// In production, use a per-second accrual model via a "borrow index"
    /// (as Aave and Compound do) for time-weighted interest.
    uint256 public constant ANNUAL_INTEREST_RATE = 5;

    /// @notice Liquidation bonus (10%).
    /// Liquidators receive 10% extra collateral as a profit incentive.
    /// Without this bonus, no rational actor would liquidate bad positions,
    /// and the protocol would eventually become insolvent.
    uint256 public constant LIQUIDATION_BONUS = 10;

    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    address public owner;

    struct Position {
        uint256 collateralEth;    // ETH locked as collateral (in wei)
        uint256 debtUsd;          // Outstanding principal debt in USD
        uint256 repayAmountUsd;   // Total owed: principal + interest
        uint256 borrowTimestamp;  // Block timestamp when loan was opened
        bool    hasActiveLoan;    // True if a loan is currently open
    }

    mapping(address => Position) public positions;

    /// @notice Internal mock USD balances.
    /// Simulates stablecoin transfers for testnet — replaced by IERC20 in production.
    mapping(address => uint256) public mockUsdBalance;

    // ═══════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event CollateralDeposited(address indexed user, uint256 amountEth, uint256 collateralValueUsd);
    event LoanBorrowed(address indexed user, uint256 principalUsd, uint256 interestUsd, uint256 repayAmountUsd);
    event LoanRepaid(address indexed user, uint256 repayAmountUsd, uint256 collateralReturnedEth);
    event CollateralWithdrawn(address indexed user, uint256 amountEth, uint256 remainingCollateralEth);
    event PositionLiquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 debtClearedUsd,
        uint256 collateralSeizedEth,
        uint256 bonusEth
    );
    event ProtocolFunded(address indexed funder, uint256 amountEth);

    // ═══════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor() {
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════
    // FUNCTION 1: DEPOSIT COLLATERAL
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit ETH as collateral to open a lending position.
     * @dev The ETH is held by the contract until withdrawn or liquidated.
     * The function is payable — ETH is sent with the transaction itself.
     *
     * TEACHING NOTE: In production, collateral can be any approved ERC-20
     * token (WETH, WBTC, USDC). Each asset gets its own LTV and liquidation
     * threshold based on its price volatility and market liquidity.
     */
    function depositCollateral() external payable {
        require(msg.value > 0, "Must deposit a positive amount of ETH");

        positions[msg.sender].collateralEth += msg.value;

        uint256 collateralValueUsd = _ethToUsd(msg.value);
        emit CollateralDeposited(msg.sender, msg.value, collateralValueUsd);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FUNCTION 2: BORROW
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Borrow mock USD against your deposited ETH collateral.
     * @param borrowAmountUsd The amount of USD to borrow (e.g. 1000 = $1,000).
     *
     * @dev Interest is a flat 5% applied at borrow time for demo simplicity.
     * The borrower receives mock USD credited to their internal balance.
     * repayAmountUsd = principal + (principal * 5 / 100)
     *
     * TEACHING NOTE: Production protocols use a variable interest rate model
     * where rates rise as pool utilisation increases. When 90% of a pool is
     * borrowed, rates spike to incentivise repayment and attract new liquidity.
     * This "utilisation curve" is a core topic in DeFi economics.
     */
    function borrow(uint256 borrowAmountUsd) external {
        require(borrowAmountUsd > 0, "Borrow amount must be positive");
        require(!positions[msg.sender].hasActiveLoan, "Repay your existing loan before borrowing again");
        require(positions[msg.sender].collateralEth > 0, "No collateral deposited");

        uint256 collateralValueUsd = _ethToUsd(positions[msg.sender].collateralEth);
        uint256 maxBorrowUsd = (collateralValueUsd * LTV_PERCENTAGE) / 100;

        require(
            borrowAmountUsd <= maxBorrowUsd,
            "Borrow amount exceeds 50% LTV. Deposit more collateral or reduce borrow amount."
        );

        // Calculate interest and total repayment amount
        uint256 interestUsd    = (borrowAmountUsd * ANNUAL_INTEREST_RATE) / 100;
        uint256 repayAmountUsd = borrowAmountUsd + interestUsd;

        // Update position
        positions[msg.sender].debtUsd         = borrowAmountUsd;
        positions[msg.sender].repayAmountUsd  = repayAmountUsd;
        positions[msg.sender].borrowTimestamp = block.timestamp;
        positions[msg.sender].hasActiveLoan   = true;

        // Credit mock USD to borrower (simulates stablecoin transfer)
        mockUsdBalance[msg.sender] += borrowAmountUsd;

        emit LoanBorrowed(msg.sender, borrowAmountUsd, interestUsd, repayAmountUsd);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FUNCTION 3: REPAY LOAN
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Repay your full outstanding loan (principal + interest).
     * On successful repayment, your ETH collateral is automatically returned.
     *
     * @dev The Checks-Effects-Interactions (CEI) pattern is strictly applied:
     *   1. CHECKS      — verify caller has an active loan and sufficient balance
     *   2. EFFECTS     — update all state mappings
     *   3. INTERACTIONS — transfer ETH last
     *
     * TEACHING NOTE: The 2016 DAO hack lost $60 million because ETH was
     * transferred BEFORE state was updated, allowing a malicious contract
     * to re-enter and drain funds repeatedly in a single transaction.
     * CEI is the primary defence against re-entrancy attacks.
     */
    function repayLoan() external {
        Position storage pos = positions[msg.sender];

        require(pos.hasActiveLoan, "No active loan to repay");
        require(
            mockUsdBalance[msg.sender] >= pos.repayAmountUsd,
            "Insufficient mock USD. Call getMockUsd() to top up your balance for testing."
        );

        uint256 repayAmount        = pos.repayAmountUsd;
        uint256 collateralToReturn = pos.collateralEth;

        // EFFECTS: update state before any ETH transfer
        mockUsdBalance[msg.sender] -= repayAmount;
        delete positions[msg.sender];

        // INTERACTIONS: return collateral to borrower
        (bool success, ) = msg.sender.call{value: collateralToReturn}("");
        require(success, "ETH collateral return failed");

        emit LoanRepaid(msg.sender, repayAmount, collateralToReturn);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FUNCTION 4: WITHDRAW COLLATERAL
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw some or all of your collateral when you have no active loan.
     * @param withdrawAmountEth Amount of ETH to withdraw, in wei.
     *
     * TEACHING NOTE: In production protocols, partial withdrawal is allowed
     * even with an active loan, as long as the remaining collateral keeps
     * the position above the liquidation threshold. This contract requires
     * full repayment first — a deliberate simplification for teaching clarity.
     */
    function withdrawCollateral(uint256 withdrawAmountEth) external {
        Position storage pos = positions[msg.sender];

        require(!pos.hasActiveLoan, "You have an active loan. Repay it before withdrawing collateral.");
        require(withdrawAmountEth > 0, "Withdraw amount must be positive");
        require(pos.collateralEth >= withdrawAmountEth, "Amount exceeds your deposited collateral");

        // CHECKS-EFFECTS-INTERACTIONS
        pos.collateralEth -= withdrawAmountEth;
        uint256 remaining  = pos.collateralEth;

        (bool success, ) = msg.sender.call{value: withdrawAmountEth}("");
        require(success, "ETH withdrawal failed");

        emit CollateralWithdrawn(msg.sender, withdrawAmountEth, remaining);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FUNCTION 5: LIQUIDATE
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Liquidate a borrower whose position has breached the 75% LTV threshold.
     * @param borrower The address of the undercollateralised borrower.
     *
     * @dev This function is permissionless — any address can call it.
     * The liquidator must hold enough mockUsd to cover the borrower's repayAmountUsd.
     * In return, they receive the borrower's full collateral plus a 10% ETH bonus.
     *
     * Example scenario:
     *   Borrower deposits 1 ETH ($3,000), borrows $1,500 (50% LTV).
     *   ETH price drops (simulated here by borrowing near the threshold).
     *   LTV rises above 75% → position is liquidatable.
     *   Liquidator pays $1,575 (debt + interest), receives 1 ETH + 0.1 ETH bonus.
     *   Liquidator profit: $300 worth of ETH for clearing a bad position.
     *
     * TEACHING NOTE: This profit incentive is the game-theoretic mechanism
     * that keeps DeFi protocols solvent. Without it, bad debt accumulates
     * and the protocol eventually fails. The bonus is funded by the borrower's
     * safety buffer — the gap between the 50% LTV cap and 75% threshold.
     *
     * PRODUCTION EXTENSION: In Aave, liquidation threshold and bonus are
     * set per asset. Volatile assets (e.g. altcoins) have lower thresholds
     * and higher bonuses to compensate liquidators for price risk.
     */
    function liquidate(address borrower) external {
        require(borrower != msg.sender, "Cannot liquidate your own position");

        Position storage pos = positions[borrower];
        require(pos.hasActiveLoan, "This address has no active loan");

        // Calculate current LTV to check if position is unhealthy
        uint256 collateralValueUsd = _ethToUsd(pos.collateralEth);
        require(collateralValueUsd > 0, "Borrower has no collateral");

        uint256 currentLtv = (pos.debtUsd * 100) / collateralValueUsd;
        require(
            currentLtv >= LIQUIDATION_THRESHOLD,
            "Position is healthy — current LTV is below the 75% liquidation threshold"
        );

        require(
            mockUsdBalance[msg.sender] >= pos.repayAmountUsd,
            "You need more mock USD to liquidate this position. Call getMockUsd() first."
        );

        uint256 debtToRepay   = pos.repayAmountUsd;
        uint256 collateralEth = pos.collateralEth;

        // Calculate 10% bonus on top of seized collateral
        uint256 bonusEth             = (collateralEth * LIQUIDATION_BONUS) / 100;
        uint256 totalEthToLiquidator = collateralEth + bonusEth;

        // Cap payout at contract balance to prevent underflow in edge cases
        if (totalEthToLiquidator > address(this).balance) {
            totalEthToLiquidator = address(this).balance;
        }

        // EFFECTS: clear borrower position and debit liquidator's mock USD
        mockUsdBalance[msg.sender] -= debtToRepay;
        delete positions[borrower];

        // INTERACTIONS: transfer collateral + bonus to liquidator
        (bool success, ) = msg.sender.call{value: totalEthToLiquidator}("");
        require(success, "Liquidation ETH transfer failed");

        emit PositionLiquidated(borrower, msg.sender, debtToRepay, collateralEth, bonusEth);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TESTNET HELPERS — Remove or restrict these in production
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Mint mock USD to your wallet for testing repayments and liquidations.
     * @param amountUsd Amount to mint (e.g. 5000 = $5,000). Capped at $100,000.
     *
     * TEACHING NOTE: This replaces a real stablecoin faucet for testnet demos.
     * In production, repayLoan() would call IERC20(usdc).transferFrom(msg.sender, ...)
     * to pull real tokens from the borrower's wallet instead.
     */
    function getMockUsd(uint256 amountUsd) external {
        require(amountUsd > 0 && amountUsd <= 100000, "Request between 1 and 100,000 mock USD");
        mockUsdBalance[msg.sender] += amountUsd;
    }

    /**
     * @notice Fund the protocol with ETH to cover liquidation bonus payouts.
     * @dev Only callable by the owner. In production, replaced by a reserve
     * factor — a small percentage of all interest that accumulates as a
     * protocol-owned insurance buffer.
     */
    function fundProtocol() external payable onlyOwner {
        require(msg.value > 0, "Must send ETH");
        emit ProtocolFunded(msg.sender, msg.value);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS — Read-only, free to call
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Get a complete snapshot of any user's current position.
     * Call this after every step in your demo to show the panel live state.
     *
     * @return collateralEth       ETH locked as collateral (in wei)
     * @return collateralValueUsd  USD value of that ETH at the mock price
     * @return debtUsd             Principal debt outstanding
     * @return repayAmountUsd      Total repayment required (principal + interest)
     * @return availableToBorrow   Additional USD borrowable right now
     * @return currentLtv          Current LTV as a percentage (0 if no debt)
     * @return isLiquidatable      True if this position can be liquidated now
     * @return hasActiveLoan       True if a loan is currently open
     */
    function getPosition(address user) external view returns (
        uint256 collateralEth,
        uint256 collateralValueUsd,
        uint256 debtUsd,
        uint256 repayAmountUsd,
        uint256 availableToBorrow,
        uint256 currentLtv,
        bool    isLiquidatable,
        bool    hasActiveLoan
    ) {
        Position storage pos = positions[user];
        collateralEth        = pos.collateralEth;
        collateralValueUsd   = _ethToUsd(collateralEth);
        debtUsd              = pos.debtUsd;
        repayAmountUsd       = pos.repayAmountUsd;
        hasActiveLoan        = pos.hasActiveLoan;

        uint256 maxBorrow    = (collateralValueUsd * LTV_PERCENTAGE) / 100;
        availableToBorrow    = maxBorrow > debtUsd ? maxBorrow - debtUsd : 0;

        if (collateralValueUsd > 0 && debtUsd > 0) {
            currentLtv     = (debtUsd * 100) / collateralValueUsd;
            isLiquidatable = currentLtv >= LIQUIDATION_THRESHOLD;
        } else {
            currentLtv     = 0;
            isLiquidatable = false;
        }
    }

    /**
     * @notice Calculate the maximum USD borrowable for a given ETH amount.
     * @param ethAmount ETH in wei.
     */
    function getMaxBorrow(uint256 ethAmount) external pure returns (uint256) {
        uint256 valueUsd = (ethAmount * ETH_PRICE_USD) / 1e18;
        return (valueUsd * LTV_PERCENTAGE) / 100;
    }

    /**
     * @notice Preview the interest and total repayment before calling borrow().
     * @param borrowAmountUsd The principal you intend to borrow.
     * @return interestUsd    The 5% interest charge.
     * @return totalRepayUsd  The total you will owe (principal + interest).
     */
    function previewBorrow(uint256 borrowAmountUsd) external pure returns (
        uint256 interestUsd,
        uint256 totalRepayUsd
    ) {
        interestUsd   = (borrowAmountUsd * ANNUAL_INTEREST_RATE) / 100;
        totalRepayUsd = borrowAmountUsd + interestUsd;
    }

    /// @notice Get the total ETH held by this contract.
    function getProtocolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Convert ETH in wei to USD using the mock price.
    /// wei = 10^18, so divide by 1e18 to get whole ETH, then multiply by price.
    function _ethToUsd(uint256 ethWei) internal pure returns (uint256) {
        return (ethWei * ETH_PRICE_USD) / 1e18;
    }

    /// @notice Accept direct ETH transfers (e.g. for funding the protocol).
    receive() external payable {}
}
