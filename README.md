# MicroLending-Solidity-Demo
A self-contained, teaching-focused DeFi micro-lending protocol written in Solidity and deployed on the Sepolia testnet. Built to demonstrate the core primitives that power production lending protocols such as Aave and Compound — collateralised borrowing, permissionless liquidation, and atomic repayment — in a form that can be read, understood, and experimented with by students new to smart contract development.
Overview
MicroLending solves a real DeFi problem: giving holders of appreciated crypto assets access to liquidity without forcing them to sell. A user locks ETH as collateral, borrows stablecoins against it, and repays the loan later to reclaim their ETH — all through a single smart contract, with no intermediaries, no paperwork, and no credit check.
The contract implements the full loan lifecycle in under 300 lines of Solidity:

Deposit ETH as collateral
Borrow mock stablecoins up to 50% of collateral value
Repay the loan with interest to unlock collateral
Withdraw collateral when no active loan exists
Liquidate unhealthy positions permissionlessly, with a profit incentive for liquidators

Deployed contract

Network: Sepolia testnet 
Verified on Etherscan: https://sepolia.etherscan.io/tx/0x470838ecbb7804f8db3bef713d0af26da701a9581fabc5382e873e2fe4eba701)

Key design decisions
This contract is deliberately simplified for teaching clarity. Each simplification is flagged in the source code with a note describing what a production version would do differently.
Checks-Effects-Interactions pattern. All state-changing functions update internal state before any ETH transfer. This defends against reentrancy attacks of the kind that drained The DAO of 60 million dollars in 2016 - a single bug that split the Ethereum network in two and reshaped Solidity best practice permanently.
Loan-to-Value gap. Borrowers can draw up to 50% of collateral value, but positions only become liquidatable above 75% LTV. The 25-point gap is a safety buffer giving borrowers time to react to falling collateral prices. Production protocols tune this buffer per asset based on volatility.
Flat interest rate. Interest is charged as a flat 5% at borrow time rather than accruing per-second. Production protocols such as Aave use variable rate models tied to pool utilisation — rates rise as liquidity becomes scarce, attracting lenders and encouraging repayment. A flat rate is a teaching simplification only.
Hardcoded price oracle. ETH is valued at a fixed $3,000. In production, this would be replaced with a Chainlink price feed reading live ETH/USD data from decentralised oracle networks. Oracle design is a critical topic in DeFi security — the Mango Markets exploit of 2022 lost over 100 million dollars through oracle manipulation.
Permissionless liquidation. Anyone can call liquidate() against an unhealthy position. The 10% ETH bonus paid to liquidators is the economic incentive that keeps the protocol solvent. Without it, bad debt would accumulate and the system would become insolvent.
Internal mock USD accounting. Rather than integrating a real ERC-20 stablecoin, the contract tracks user stablecoin balances internally. This keeps the contract self-contained for testnet demos. In production, repayLoan() would call IERC20(usdc).transferFrom() to pull real tokens from the borrower's wallet.
Deployment process
The contract can be deployed entirely from a web browser with no local setup:

Open Remix IDE and create a new file, MicroLending.sol
Paste the contract source and compile with Solidity 0.8.20 and the optimiser enabled
Install MetaMask and switch to the Sepolia testnet
Fund the deploying account with Sepolia ETH from a public faucet such as sepoliafaucet.com
In Remix, set the environment to Injected Provider – MetaMask and deploy
Call fundProtocol() with a small ETH value to provide liquidity for liquidation bonuses
Interact with the contract through Remix's UI, or verify its source code on Sepolia Etherscan for public auditability

Technical stack

Language: Solidity ^0.8.20
Development environment: Remix IDE (browser-based, zero-install)
Wallet: MetaMask
Test network: Sepolia (Ethereum's primary public testnet)
Block explorer: Sepolia Etherscan

Notes
This contract was built as a live-demonstrated teaching artefact for a FinTech lecturer role. It is intentionally simpler than any contract that should ever handle real funds. Every simplification is flagged in the source with inline comments explaining what a production version would do differently and why.
The contract is designed to be walked through function-by-function in a classroom setting, with each function introducing one core concept — depositCollateral() introduces the payable keyword and msg.value; borrow() introduces state mappings and parameter validation; repayLoan() introduces Checks-Effects-Interactions and atomic settlement; liquidate() introduces permissionless functions, economic incentives, and the game theory that keeps DeFi protocols solvent.
A 12-week module could be built around extending this contract — swapping the hardcoded price for a Chainlink oracle in week seven, replacing mock USD with a real ERC-20 stablecoin in week eight, and implementing a variable interest rate curve in week ten. Each extension maps to a real feature found in production protocols, giving students a clear progression from teaching contract to production-grade understanding.
Licence
MIT — see LICENSE for details.
Author
Sibi Chakravarthi
