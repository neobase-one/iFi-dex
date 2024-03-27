import { ethers } from "hardhat";

async function main() {
  let tx_hash =
    "0xd5f93074252d8cefe7cd67f253095691615a2394f90e19198e44670359b4122c";

  let tx: any = await ethers.provider.getTransaction(tx_hash);
  try {
    let code = await ethers.provider.call(tx, tx.blockNumber);
    console.log({ code });
  } catch (err: any) {
    console.log({ err });
    let code = err.data.replace("Reverted", "");
    let reason = ethers.utils.toUtf8String("0x" + code.substr(138));
    console.log("revert reason:", reason);
  }
}

main();
