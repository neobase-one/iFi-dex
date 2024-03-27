import { ethers } from "hardhat";
import { ZERO_ADDR } from "../../test/FixedPoint";
import { CrocQuery, CrocSwapDex, MockERC20 } from "../../typechain";
import addresses from "./deployedContractAddresses.json";
import { attachToContracts } from "./utils";

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

  console.log("Querying current tick");
  let tick = await query.queryCurveTick(
    token_1.address,
    token_2.address,
    36000,
    override
  );
  console.log("Current tick: ", tick);

  // Mint concentrated liquidity
  let mintConcentratedLiqCmd = abi.encode(
    [
      "uint8",
      "address",
      "address",
      "uint256",
      "int24",
      "int24",
      "uint128",
      "uint128",
      "uint128",
      "uint8",
      "address",
    ],
    [
      11, // code (mint concentrated liquidity in base token liq)
      token_1.address, // quote token
      token_2.address, // base token
      36000, // poolIDX
      tick - 75, // tickLower
      tick + 75, // tickUpper
      BigNumber.from("10000000"), // amount of base token to send
      BigNumber.from("18446744073"), // min price
      BigNumber.from("18446744073709000"), // max price
      0, // reserve flag
      ZERO_ADDR, // lp conduit address (0 if not using)
    ]
  );
  let tx = await dex.userCmd(2, mintConcentratedLiqCmd, {
    gasLimit: 6000000,
  });
  await tx.wait();
  console.log(tx);

  console.log({
    Position: await query.queryRangeTokens(
      deployer.address,
      token_1.address,
      token_2.address,
      36000,
      tick - 75,
      tick + 75
    ),
  });
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
