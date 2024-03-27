import { ethers } from "hardhat";
import { ZERO_ADDR } from "../../test/FixedPoint";
import { CrocQuery, CrocSwapDex, MockERC20 } from "../../typechain";
import addresses from "./deployedContractAddresses.json";
import { attachToContracts } from "./utils";
import { assert } from "console";

const { BigNumber } = require("ethers");
var AbiCoder = require("@ethersproject/abi").AbiCoder;

const abi = new AbiCoder();

let tokens = {
  althea: ZERO_ADDR,
  token_1: "0x0412C7c846bb6b7DC462CF6B453f76D8440b2609",
  token_2: "0x30dA8589BFa1E509A319489E014d384b87815D89",
};

let override = {
  gasPrice: BigNumber.from("10").pow(9).mul(4),
  gasLimit: 10000000,
};

async function main() {
  let deployer = (await ethers.getSigners())[0];
  let { dex, query } = await attachToContracts(addresses);

  let token_factory = await ethers.getContractFactory("MockERC20");
  let token_1 = token_factory.attach(tokens.token_1) as MockERC20;
  let token_2 = token_factory.attach(tokens.token_2) as MockERC20;

  const token1Bal = await token_1.balanceOf(deployer.address);
  const token2Bal = await token_2.balanceOf(deployer.address);

  const token_1_for_2 = true;

  let swapTx = await dex.swap(
    token_1.address,
    token_2.address,
    36000,
    !token_1_for_2, // Swap token 2 for token 1
    true,
    BigNumber.from("1000000"),
    0,
    BigNumber.from("16446744073709"),
    BigNumber.from("1080000000000000000"),
    0
  );

  await swapTx.wait();

  // get balances of USDC and cNOTE post-swap
  const token1BalPost = await token_1.balanceOf(deployer.address);
  const token2BalPost = await token_2.balanceOf(deployer.address);
  console.log(
    "token1 balance change: ",
    token1Bal.toString(),
    " -> ",
    token1BalPost.toString()
  );
  console.log(
    "token2 balance change: ",
    token2Bal.toString(),
    " -> ",
    token2BalPost.toString()
  );
  if (!token1BalPost.sub(token1Bal).gt(500000)) {
    console.log("Expected an increase in token1 balance");
    process.exit(1);
  }

  if (!token2Bal.sub(token2BalPost).gt(500000000000)) {
    console.log("Expected a decrease in token2 balance");
    process.exit(1);
  }

  console.log("Swap successful");
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
