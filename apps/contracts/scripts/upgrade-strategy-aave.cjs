const { ethers, upgrades } = require("hardhat");
require("dotenv").config({ path: `.env` });
require("dotenv").config({
  path: `.env.${process.env.HARDHAT_NETWORK}`,
  override: true,
});

async function main() {
  // Validate environment variables
  const usdcAddress = process.env.USDC_ADDRESS;
  const fundTokenAddress = process.env.FUND_TOKEN_ADDRESS;

  if (!usdcAddress || !fundTokenAddress) {
    throw new Error(
      "Please set USDC_ADDRESS and FUND_TOKEN_ADDRESS environment variables."
    );
  }

  // Deploy contract using the UUPS proxy pattern
  const Strategy = await ethers.getContractFactory("AaveStrategy");
  const fundContract = await upgrades.upgradeProxy(
    process.env.AAVE_STRATEGY_ADDRESS,
    Strategy
  );

  console.log("Strategy upgraded:", fundContract.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
