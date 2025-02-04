import { TestPool, makeTokenPool, Token, makeEtherPool, POOL_IDX, ERC20Token, makeStandaloneToken, makeTokenTriangle } from './FacadePool'
import { expect } from "chai";
import "@nomiclabs/hardhat-ethers";
import hardhat, { ethers } from 'hardhat';
import { toSqrtPrice, fromSqrtPrice, maxSqrtPrice, minSqrtPrice, ZERO_ADDR } from './FixedPoint';
import { solidity } from "ethereum-waffle";
import chai from "chai";
import { MockERC20 } from '../typechain/MockERC20';
import { BigNumber, ContractFactory } from 'ethers';
import { HotProxy, AltheaDexContinuousMultiTokenIncentives } from '../typechain';
import {mine} from 'viem/_types/actions/test/mine';

chai.use(solidity);

describe('AmbientIncentives', () => {
    let test1: TestPool
    let test2: TestPool
    let test3: TestPool
    let baseToken: ERC20Token
    let quoteToken: ERC20Token
    let rewardToken: ERC20Token
    const feeRate = 225 * 100
    let incentives : AltheaDexContinuousMultiTokenIncentives
    let baseQuotePoolId: string

    beforeEach("deploy",  async () => {
        [test1, test2, test3] = await makeTokenTriangle()
        baseToken = await test1.base
        quoteToken = await test1.quote
        rewardToken = await makeStandaloneToken();

        await test1.initPool(feeRate, 0, 1, 1.5)
        await test2.initPool(feeRate, 0, 1, 1.5)
        test1.useHotPath = true;
        test2.useHotPath = true;
 
        await test1.base.contract.deposit(await (await test1.trader).getAddress(), ethers.utils.parseEther("1000000"))
        await test1.quote.contract.deposit(await (await test1.trader).getAddress(), ethers.utils.parseEther("1000000"))
        await test1.base.approve(await test1.trader, (await test1.dex).address, ethers.utils.parseEther("1000000"))
        await test1.quote.approve(await test1.trader, (await test1.dex).address, ethers.utils.parseEther("1000000"))
        await test2.base.approve(await test1.trader, (await test1.dex).address, ethers.utils.parseEther("1000000"))
        await test2.quote.approve(await test1.trader, (await test1.dex).address, ethers.utils.parseEther("1000000"))


        let incentivesFactory = await ethers.getContractFactory("AltheaDexContinuousMultiTokenIncentives") as ContractFactory;
        incentives = await incentivesFactory.deploy((await test1.dex).address, ZERO_ADDR, [], [], [], []) as AltheaDexContinuousMultiTokenIncentives;
 
        baseQuotePoolId = ethers.utils.keccak256(
            ethers.utils.defaultAbiCoder.encode(
                ["address", "address", "uint256"],
                [baseToken.address, quoteToken.address, POOL_IDX]
            )
        );
    })

    it("mint, register, withdraw rewards", async () => {
        let liq = 1000000;
        await test1.testMintAmbient(liq); 
        liq = 1000000 * 1024; // The liq input is converted to units of 1024 for the position, so we update this value for the future

        const rateNum = 10 ^ 18; // 1 token
        const rateDen = 10 * 1024 * (10^18) // Every 10 blocks, every 1024 * 10^18 liquidity units
        const rate = rateNum / rateDen;
        await incentives.createOrModifyAmbientRewardsProgram(
            baseQuotePoolId, 
            rewardToken.address, 
            rateNum,  
            rateDen, 
        );

        // Fund the incentives contract with baseToken
        await rewardToken.contract.deposit(await incentives.address, ethers.utils.parseUnits("100", 18));

        await incentives.registerForAmbientRewards(baseQuotePoolId, rewardToken.address);

        // Mine 9 blocks to generate rewards, expecting a 10th block on the withdrawRewards() call
        await hardhat.network.provider.send("hardhat_mine", ["0x9"]);

        const traderAddress = await (await test1.trader).getAddress();

        const pendingRewards = await incentives.getPendingRewards(baseQuotePoolId, traderAddress, rewardToken.address);
        expect(pendingRewards).to.eq(liq * rate * 9);

        const expectedRewards = liq * 10 * rate

        const initialBalance = await rewardToken.balanceOf(traderAddress);

        await incentives.withdrawRewards(baseQuotePoolId, rewardToken.address);

        const finalBalance = await rewardToken.balanceOf(traderAddress);

        expect(finalBalance.sub(initialBalance)).to.equal(expectedRewards);
    });

    it("Insufficient Balance error when rewards are not funded", async () => {
        let liq = 1000000;
        await test1.testMintAmbient(liq); 
        liq = 1000000 * 1024; // The liq input is converted to units of 1024 for the position, so we update this value for the future

        const rateNum = 10 ^ 18; // 1 token
        const rateDen = 10 * 1024 * (10^18) // Every 10 blocks, every 1024 * 10^18 liquidity units
        const rate = rateNum / rateDen;
        await incentives.createOrModifyAmbientRewardsProgram(
            baseQuotePoolId, 
            rewardToken.address, 
            rateNum,  
            rateDen, 
        );

        await incentives.registerForAmbientRewards(baseQuotePoolId, rewardToken.address);

        // Mine 9 blocks to generate rewards, expecting a 10th block on the withdrawRewards() call
        await hardhat.network.provider.send("hardhat_mine", ["0x9"]);

        const traderAddress = await (await test1.trader).getAddress();

        const pendingRewards = await incentives.getPendingRewards(baseQuotePoolId, traderAddress, rewardToken.address);
        expect(pendingRewards).to.eq(liq * rate * 9);

        await expect(incentives.withdrawRewards(baseQuotePoolId, rewardToken.address)).to.be.revertedWith("Insufficient Balance");
    });

    it("mint, register, withdraw rewards from multiple pools", async () => {
        const poolId1 = baseQuotePoolId;
        const poolId2 = ethers.utils.keccak256(
            ethers.utils.defaultAbiCoder.encode(
                ["address", "address", "uint256"],
                [(await test2.base).address, (await test2.quote).address, POOL_IDX]
            )
        );

        const rateNum1 = 10 ^ 18; // 1 token
        const rateDen1 = 10 * 1024 * (10 ^ 18); // Every 10 blocks, every 1024 * 10^18 liquidity units
        const rate1 = rateNum1 / rateDen1;
        await incentives.createOrModifyAmbientRewardsProgram(
            poolId1, 
            rewardToken.address, 
            rateNum1,  
            rateDen1, 
        );
        const rateNum2 = 5 ^ 18; // 0.5 token
        const rateDen2 = 10 * 1024 * (10 ^ 18); // Every 10 blocks, every 1024 * 10^18 liquidity units
        const rate2 = rateNum2 / rateDen2;
        await incentives.createOrModifyAmbientRewardsProgram(
            poolId2, 
            rewardToken.address, 
            rateNum2,  
            rateDen2, 
        );

        // Setup the liquidity positions
        let liq1 = 1000000;
        await test1.testMintAmbient(liq1); 
        liq1 = 1000000 * 1024; // The liq input is converted to units of 1024 for the position, so we update this value for the future
        let liq2 = 2000000;
        await test2.testMintAmbient(liq2); 
        liq2 = 2000000 * 1024; // The liq input is converted to units of 1024 for the position, so we update this value for the future

        // Fund the incentives contract with rewardToken for both programs
        await rewardToken.contract.deposit(await incentives.address, ethers.utils.parseUnits("100", 18));

        // Register for both rewards programs, with a 10 block head start for the first program
        await incentives.registerForAmbientRewards(poolId1, rewardToken.address); // 1-0 2-?
        // Mine 9 blocks to generate rewards on the first program, registration on the second will be the 10th block
        await hardhat.network.provider.send("hardhat_mine", ["0x9"]); // 1-9 2-?
        await incentives.registerForAmbientRewards(poolId2, rewardToken.address); // 1-10 2-0

        // Mine 9 blocks to generate rewards on the second program, expecting a 10th block on the withdrawRewards() call
        await hardhat.network.provider.send("hardhat_mine", ["0x9"]); // 1-19 2-9

        const traderAddress = await (await test1.trader).getAddress();

        // Check that the pending rewards are returned correctly
        const pendingRewards1 = await incentives.getPendingRewards(poolId1, traderAddress, rewardToken.address);
        const pendingRewards2 = await incentives.getPendingRewards(poolId2, traderAddress, rewardToken.address);
        expect(pendingRewards1.toNumber()).to.eq(Math.floor(liq1 * rate1 * 19));
        expect(pendingRewards2).to.eq(Math.floor(liq2 * rate2 * 9));

        // Check the totalOwed output matches the pending rewards too
        const totalOwed1 = await incentives.totalOwed(poolId1, rewardToken.address);
        const totalOwed2 = await incentives.totalOwed(poolId2, rewardToken.address);
        expect(totalOwed1).to.eq(pendingRewards1);
        expect(totalOwed2).to.eq(pendingRewards2);

        const expectedRewards1 = liq1 * 20 * rate1;
        const expectedRewards2 = liq2 * 11 * rate2;

        const initialBalance = await rewardToken.balanceOf(traderAddress);

        // Withdraw both rewards on the same block
        await incentives.withdrawRewards(poolId1, rewardToken.address); // 1-20 2-10
        await incentives.withdrawRewards(poolId2, rewardToken.address); // 1-21 2-11

        const finalBalance = await rewardToken.balanceOf(traderAddress);

        expect(finalBalance.sub(initialBalance)).to.equal(Math.floor(expectedRewards1 + expectedRewards2));
    });

    it("mint, register, withdraw rewards from multiple incentives contracts", async () => {
        const rateNum1 = 10 ^ 18; // 1 token
        const rateDen1 = 10 * 1024 * (10 ^ 18); // Every 10 blocks, every 1024 * 10^18 liquidity units
        const rate1 = rateNum1 / rateDen1;

        const rateNum2 = 5 ^ 18; // 0.5 token
        const rateDen2 = 10 * 1024 * (10 ^ 18); // Every 10 blocks, every 1024 * 10^18 liquidity units
        const rate2 = rateNum2 / rateDen2;

        // Deploy a second incentives contract
        let incentivesFactory = await ethers.getContractFactory("AltheaDexContinuousMultiTokenIncentives") as ContractFactory;
        let incentives2 = await incentivesFactory.deploy((await test1.dex).address, ZERO_ADDR, [], [], [], []) as AltheaDexContinuousMultiTokenIncentives;

        await incentives.createOrModifyAmbientRewardsProgram(
            baseQuotePoolId, 
            rewardToken.address, 
            rateNum1,  
            rateDen1, 
        );

        await incentives2.createOrModifyAmbientRewardsProgram(
            baseQuotePoolId, 
            rewardToken.address, 
            rateNum2,  
            rateDen2, 
        );

        // Setup the liquidity position
        let liq = 1000000;
        await test1.testMintAmbient(liq); 
        liq = 1000000 * 1024; // The liq input is converted to units of 1024 for the position, so we update this value for the future

        // Fund both incentives contracts with rewardToken
        await rewardToken.contract.deposit(await incentives.address, ethers.utils.parseUnits("100", 18));
        await rewardToken.contract.deposit(await incentives2.address, ethers.utils.parseUnits("100", 18));

        // Register for both rewards programs
        await incentives.registerForAmbientRewards(baseQuotePoolId, rewardToken.address); // 1-0 2-?
        await incentives2.registerForAmbientRewards(baseQuotePoolId, rewardToken.address); // 1-1 2-0

        // Mine 9 blocks to generate rewards, expecting a 10th block on the withdrawRewards() call
        await hardhat.network.provider.send("hardhat_mine", ["0x8"]); // 1-9 2-8

        const traderAddress = await (await test1.trader).getAddress();

        // Check that the pending rewards are returned correctly
        const pendingRewards1 = await incentives.getPendingRewards(baseQuotePoolId, traderAddress, rewardToken.address);
        const pendingRewards2 = await incentives2.getPendingRewards(baseQuotePoolId, traderAddress, rewardToken.address);
        expect(pendingRewards1.toNumber()).to.eq(Math.floor(liq * rate1 * 9));
        expect(pendingRewards2.toNumber()).to.eq(Math.floor(liq * rate2 * 8));

        const expectedRewards1 = liq * 10 * rate1;
        const expectedRewards2 = liq * 10 * rate2;

        const initialBalance = await rewardToken.balanceOf(traderAddress);

        // Withdraw rewards from both incentives contracts
        await incentives.withdrawRewards(baseQuotePoolId, rewardToken.address); // 1-10 2-9
        await incentives2.withdrawRewards(baseQuotePoolId, rewardToken.address); // 1-11 2-10

        const finalBalance = await rewardToken.balanceOf(traderAddress);

        expect(finalBalance.sub(initialBalance)).to.equal(Math.floor(expectedRewards1 + expectedRewards2));
    });

    it("randomized users with positions in the incentivized pool", async () => {
        const numUsers = Math.floor(Math.random() * 41) + 10; // Random number between 10 and 50
        const users = [];
        const liqPositions = [];
        const positionsBlockStarted = [];

        const rateNum = ethers.utils.parseEther("1"); // 1 token
        const rateDen = ethers.utils.parseEther("10240"); // Every 10 blocks, every 1024 * 10^18 liquidity units

        await incentives.createOrModifyAmbientRewardsProgram(
            baseQuotePoolId, 
            rewardToken.address, 
            rateNum,  
            rateDen, 
        );

        for (let i = 0; i < numUsers; i++) {
            const user = ethers.Wallet.createRandom().connect(ethers.provider);
            users.push(user);
            // Fund the new user
            await (await test1.trader).sendTransaction({to: users[i].address, value: ethers.utils.parseEther("1")});

            const liq = ethers.utils.parseEther("1").mul(BigNumber.from(Math.floor(Math.random() * (5000000 - 100 + 1)) + 100));
            const finalPosLiq = liq.mul(1024); // Minting positions always multiplies input liq by 1024
            await test1.base.contract.deposit(user.address, finalPosLiq.mul(1024));
            await test1.quote.contract.deposit(user.address, finalPosLiq.mul(1024));
            await test1.base.contract.connect(user).approve((await test1.dex).address, finalPosLiq.mul(1024));
            await test1.quote.contract.connect(user).approve((await test1.dex).address, finalPosLiq.mul(1024));
            await test1.testMintAmbientFrom(user, liq); 

            liqPositions.push(finalPosLiq);
            await incentives.connect(user).registerForAmbientRewards(baseQuotePoolId, rewardToken.address);
            positionsBlockStarted[i] = await hardhat.ethers.provider.getBlockNumber();
        }

        // Mine 9 blocks to generate rewards, expecting a 10th block on the withdrawRewards() call
        await hardhat.network.provider.send("hardhat_mine", ["0x9"]);

        for (let i = 0; i < numUsers; i++) {
            const user = users[i];
            const liq = liqPositions[i];
            const pendingRewards = await incentives.getPendingRewards(baseQuotePoolId, user.address, rewardToken.address);
            rewardToken.contract.deposit(await incentives.address, pendingRewards.mul(2));
            const pendingBlockDelta = BigNumber.from(Math.floor(await hardhat.ethers.provider.getBlockNumber())).sub(positionsBlockStarted[i]);
            const minedBlockDelta = pendingBlockDelta.add(2); // add 2 because we have a 2 block lag in pending -> actual (reward funding block, withdraw block)
            expect(pendingRewards).to.eq(liq.mul(pendingBlockDelta).mul(rateNum).div(rateDen), "Pending rewards failed for user " + i);

            const expectedRewards = liq.mul(minedBlockDelta).mul(rateNum).div(rateDen);
            const initialBalance = await rewardToken.balanceOf(user.address);

            await incentives.connect(user).withdrawRewards(baseQuotePoolId, rewardToken.address);

            const finalBalance = await rewardToken.balanceOf(user.address);
            expect(finalBalance.sub(initialBalance)).to.equal(expectedRewards, "Final balance failed for user " + i);
        }
    });

})