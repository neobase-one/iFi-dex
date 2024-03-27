import { ethers } from "hardhat";
import { BigNumber } from "ethers";
import { ZERO_ADDR } from "../../test/FixedPoint";
import { CrocSwapDex } from "../../typechain/CrocSwapDex";
import { ColdPath } from "../../typechain/ColdPath";
import { WarmPath } from "../../typechain/WarmPath";
import { LongPath } from "../../typechain/LongPath";
import { MicroPaths } from "../../typechain/MicroPaths";
import { CrocPolicy } from "../../typechain/CrocPolicy";
import { CrocQuery } from "../../typechain/CrocQuery";
import { HotPath } from "../../typechain/HotPath";
import {
  CrocImpact,
  KnockoutFlagPath,
  KnockoutLiqPath,
  MockERC20,
  SafeModePath,
} from "../../typechain";
import { assert } from "console";
import addresses from "./deployedContractAddresses.json";
import { attachToContracts } from "./utils";

let tokens = {
  althea: ZERO_ADDR,
  token_1: "0x0412C7c846bb6b7DC462CF6B453f76D8440b2609",
  token_2: "0x30dA8589BFa1E509A319489E014d384b87815D89",
};

let override = {
  gasPrice: BigNumber.from("10").pow(9).mul(10),
  gasLimit: 17000000,
};

async function main() {
  let deployer = (await ethers.getSigners())[0];
  let abi = new ethers.utils.AbiCoder();
  let cmd;
  let tx;
  let receipt;

  let { dex, query } = await attachToContracts(addresses);

  let token_factory = await ethers.getContractFactory("MockERC20");
  let token_1 = token_factory.attach(tokens.token_1) as MockERC20;
  let token_2 = token_factory.attach(tokens.token_2) as MockERC20;

  // 1. approve dai and usdc for dex
  //   console.log("Approving tokens for use by the DEX");
  //   let approveDai = await dai.approve(dex.address, BigNumber.from(10).pow(36));
  //   await approveDai.wait();
  //   await setTimeout(() => {}, 1000);
  //   console.log("Approving tokens for use by the DEX");
  //   let approveUSDC = await usdc.approve(dex.address, BigNumber.from(10).pow(36));
  //   await approveUSDC.wait();

  console.log({
    Token1Balance: await token_1.balanceOf(deployer.address),
    Token1Approval: await token_1.allowance(deployer.address, dex.address),
    Token2Balance: await token_2.balanceOf(deployer.address),
    Token2Approval: await token_2.allowance(deployer.address, dex.address),
  });

  /*
	/	2. set new pool liquidity (amount to lock up for new pool)
	/	   params = [code, liq]
  / liq is in liquidity units, so this is the minimum possible lockup amount
	*/
  //   console.log("Setting pool liquidity lockup to 1");
  //   let setPoolLiqCmd = abi.encode(["uint8", "uint128"], [112, 1]);
  //   tx = await dex.protocolCmd(3, setPoolLiqCmd, true, override);
  //   await tx.wait();
  //   console.log("Pool liquidity set: ", tx);

  /*
	/  3. Create new pool template
	/     params = [code, poolIDX, feeRate, tickSize, jitThresh, knockout, oracle]
	*/
  //   console.log("Creating new pool template");
  //   let templateCmd = abi.encode(
  //     ["uint8", "uint256", "uint16", "uint16", "uint8", "uint8", "uint8"],
  //     [110, 36000, 100, 1, 8, 32 + 6, 0]
  //   );
  //   tx = await dex.protocolCmd(3, templateCmd, false, override);
  //   await tx.wait();
  //   console.log("Pool template created: ", tx);

  // Query the created template to ensure it was successfully set
  console.log({ Template: await query.queryPoolTemplate(36000) });

  /*
  /  4. Initialize the new pool with USDC and cNOTE
  /     params = [code, token0, token1, poolIDX, sqrtPrice]
  */
  let initPoolArgs = [
    71,
    token_1.address,
    token_2.address,
    36000,
    toSqrtPrice(Math.pow(10, -12)),
  ];
  console.log("Initializing new pool: ", initPoolArgs);
  let initPoolCmd = abi.encode(
    ["uint8", "address", "address", "uint256", "uint128"],
    initPoolArgs
  );
  console.log({ initPoolCmd });
  tx = await dex.userCmd(3, initPoolCmd, override);
  await tx.wait();
  console.log("Pool initialized: ", tx);
}

const PRECISION = 100000000;
const Q_64 = BigNumber.from(2).pow(64);
function toSqrtPrice(price: number) {
  let sqrtFixed = Math.round(Math.sqrt(price) * PRECISION);
  return BigNumber.from(sqrtFixed).mul(Q_64).div(PRECISION);
}

main().then(
  () => {
    process.exit(0);
  },
  (err) => {
    console.log("FAILURE", err);
    process.exit(0);
  }
);
