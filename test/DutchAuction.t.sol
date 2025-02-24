// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DutchAuction} from "../src/DutchAuction.sol";
import "forge-std/Test.sol";

contract MockDutchAuction is DutchAuction {
    mapping(address => uint256) public buyerItemCount;

    bool public unsoldWithdrawn;

    constructor(
        address _seller,
        uint256 _startPrice,
        uint256 _floorPrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _inventory
    ) DutchAuction(_seller, _startPrice, _floorPrice, _startTime, _duration, _inventory) {
        // No custom logic needed for now
    }

    // Here you would normally transfer the actual assets to the winner(e.g. the NFT)
    // For testing purposes, we just set the winnerAssetRecipient to the winner
    function _transferAssetToBuyer(address buyer_, uint256 quantity) internal override {
        buyerItemCount[buyer_] += quantity;
    }

    // Here you would normally transfer the unsold assets to the seller(e.g. the NFT) if there was no winner
    // For testing purposes, we just set the a boolean flag
    function _withdrawUnsoldAssets(address, /* seller_ */ uint256 /* quantity */ ) internal override {
        unsoldWithdrawn = true;
    }
}

contract DutchAuctionTest is Test {
    // Test addresses
    address seller = address(0xA1);
    address buyer1 = address(0xB1);
    address buyer2 = address(0xB2);
    address randomUser = address(0xC1);

    // Auction parameters
    uint256 startPrice = 1 ether;
    uint256 floorPrice = 0.1 ether;
    uint256 startTime = 1000; // We'll warp to 1000 in setUp
    uint256 duration = 1 days;
    uint256 inventory = 50; // 50 identical items

    MockDutchAuction auction;

    function setUp() external {
        // Warp to a known start time
        vm.warp(startTime);

        // Deploy the mock Dutch Auction
        auction = new MockDutchAuction(seller, startPrice, floorPrice, startTime, duration, inventory);

        // Give test addresses some ETH
        vm.deal(buyer1, 10 ether);
        vm.deal(buyer2, 10 ether);
        vm.deal(randomUser, 1 ether);
    }

    // -----------------------------------
    // Initialization & Constructor Tests
    // -----------------------------------

    function test_constructorInitializesStateCorrectly() external {
        assertEq(auction.getSeller(), seller, "Seller should match constructor arg");
        assertEq(auction.getStartTime(), startTime, "startTime mismatch");
        assertEq(auction.getStartPrice(), startPrice, "startPrice mismatch");
        assertEq(auction.getFloorPrice(), floorPrice, "floorPrice mismatch");
        assertEq(auction.getInventory(), inventory, "inventory mismatch");
        assertFalse(auction.isFinished(), "Auction should not be finished initially");
    }

    function test_constructorEmitsAuctionCreatedEvent() external {
        vm.expectEmit();
        emit DutchAuction.AuctionCreated(seller, startPrice, floorPrice, startTime, duration, inventory);
        new MockDutchAuction(seller, startPrice, floorPrice, startTime, duration, inventory);
    }

    function test_constructor_RevertWhen_ZeroDuration() external {
        vm.expectRevert(DutchAuction.InvalidDuration.selector);
        new MockDutchAuction(
            seller,
            startPrice,
            floorPrice,
            startTime + 10,
            0, // zero duration
            10
        );
    }

    function test_constructor_RevertWhen_StartTimeInPast() external {
        // block.timestamp = 1000 in setUp, so _startTime < block.timestamp fails
        vm.expectRevert(
            abi.encodeWithSelector(
                DutchAuction.StartTimeInPast.selector,
                900, // startTime
                1000 // blockTimestamp
            )
        );
        new MockDutchAuction(seller, startPrice, floorPrice, 900, 1 days, 10);
    }

    function test_constructor_RevertWhen_ZeroInventory() external {
        vm.expectRevert(DutchAuction.InvalidInventory.selector);
        new MockDutchAuction(
            seller,
            startPrice,
            floorPrice,
            startTime + 10,
            1 days,
            0 // zero inventory
        );
    }

    // // -----------------------------------
    // // Price Function Tests
    // // -----------------------------------

    function test_currentPriceDecreasesOverTime() external {
        // Initially (block.timestamp == startTime), price = startPrice
        uint256 p0 = auction.currentPrice();
        assertEq(p0, startPrice, "price at startTime should be startPrice");

        // Warp half the duration => price should be halfway between startPrice and floorPrice
        vm.warp(startTime + (duration / 2));
        uint256 pHalf = auction.currentPrice();
        uint256 expectedHalf = floorPrice + ((startPrice - floorPrice) / 2);
        assertEq(pHalf, expectedHalf, "price at half-time mismatch");

        // Warp to end => price = floorPrice
        vm.warp(startTime + duration + 1);
        uint256 pEnd = auction.currentPrice();
        assertEq(pEnd, floorPrice, "price after endTime should be floorPrice");
    }

    // // -----------------------------------
    // // Buying Tests
    // // -----------------------------------

    function test_buyPurchasesItems() external {
        // buyer1 buys 5 items at the start price
        uint256 quantity = 5;
        uint256 costAtStart = quantity * startPrice; // 5 * 1 ETH = 5 ETH

        vm.startPrank(buyer1);
        vm.expectEmit();
        emit DutchAuction.Purchased(buyer1, quantity, costAtStart);
        auction.buy{value: costAtStart}(quantity);

        // Check inventory
        uint256 invAfter = auction.getInventory();
        assertEq(invAfter, inventory - quantity, "inventory not decreased by quantity");

        // buyer1 should have 5 items
        assertEq(auction.buyerItemCount(buyer1), 5, "buyer1 item count mismatch");
    }

    function test_buyRefundsExcess() external {
        uint256 quantity = 5;
        uint256 costAtStart = quantity * startPrice;

        uint256 userBalanceBefore = buyer1.balance;
        uint256 contractBalanceBefore = address(auction).balance;

        vm.startPrank(buyer1);
        // Send extra 1 ether and then check that the refund works
        auction.buy{value: costAtStart + 1 ether}(quantity);

        uint256 userBalanceAfter = buyer1.balance;
        uint256 contractBalanceAfter = address(auction).balance;

        assertEq(userBalanceAfter, userBalanceBefore - costAtStart, "user balance not decreased correctly");
        assertEq(contractBalanceAfter, contractBalanceBefore + costAtStart, "contract balance not increased correctly");
    }

    function test_buyAtLastSecondSucceeds() external {
        vm.warp(startTime + duration);
        vm.startPrank(buyer1);

        uint256 price = auction.currentPrice();
        vm.expectEmit();
        emit DutchAuction.Purchased(buyer1, 1, price);
        auction.buy{value: price}(1);
    }

    function test_buy_RevertWhen_AuctionNotStarted() external {
        // Deploy a new auction that starts in the future
        MockDutchAuction futureAuction = new MockDutchAuction(
            seller,
            startPrice,
            floorPrice,
            startTime + 1000, // starts 1000 sec in the future
            duration,
            inventory
        );

        vm.startPrank(buyer1);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        futureAuction.buy{value: 1 ether}(1);
    }

    function test_buy_RevertWhen_AuctionEnded() external {
        // warp after end
        vm.warp(startTime + duration + 1);

        vm.startPrank(buyer1);
        vm.expectRevert(DutchAuction.AuctionEnded.selector);
        auction.buy{value: 1 ether}(1);
    }

    function test_buy_RevertWhen_InvalidQuantity() external {
        // Zero quantity
        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.InvalidQuantity.selector, 0, inventory));
        auction.buy{value: 1 ether}(0);

        // Exceed inventory
        vm.prank(buyer2);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.InvalidQuantity.selector, inventory + 1, inventory));
        auction.buy{value: 10 ether}(inventory + 1);
    }

    function test_buy_RevertWhen_InsufficientPayment() external {
        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.InsufficientAmount.selector, 1.5 ether, 2 ether));
        auction.buy{value: 1.5 ether}(2);
    }

    // // -----------------------------------
    // // Seller Proceeds Tests
    // // -----------------------------------

    function test_withdrawSellerProceeds() external {
        // buyer1 buys 2 items at start price
        uint256 testStartPrice = auction.currentPrice();
        vm.prank(buyer1);
        auction.buy{value: testStartPrice * 2}(2);

        // buyer2 buys one item after half duration
        vm.warp(startTime + (duration / 2));
        vm.prank(buyer2);
        uint256 halfDurationPrice = auction.currentPrice();
        auction.buy{value: halfDurationPrice}(1);

        // The contract now has testStartPrice * 2 + halfDurationPrice ETH. Let seller withdraw
        uint256 sellerBalBefore = seller.balance;
        vm.expectEmit();
        emit DutchAuction.FundsWithdrawn(seller, testStartPrice * 2 + halfDurationPrice);
        auction.withdrawSellerProceeds();
        uint256 sellerBalAfter = seller.balance;
        assertEq(
            sellerBalAfter,
            sellerBalBefore + testStartPrice * 2 + halfDurationPrice,
            "seller should get the funds in the contract"
        );
    }

    // // -----------------------------------
    // // Auction End & Unsold Withdrawal
    // // -----------------------------------

    function test_isFinishedByTime() external {
        // initially not finished
        assertFalse(auction.isFinished(), "should not be finished yet");

        // warp after end
        vm.warp(startTime + duration + 1);
        assertTrue(auction.isFinished(), "should be finished after time expires");
    }

    function test_isFinishedByInventory() external {
        // buyer1 purchases entire inventory (50) at once
        uint256 price = auction.currentPrice();
        vm.deal(buyer1, price * inventory);
        vm.prank(buyer1);
        auction.buy{value: price * inventory}(inventory);
        // now inventory=0 => isFinished should be true
        assertTrue(auction.isFinished(), "auction should be finished if inventory=0");
    }

    function test_withdrawUnsoldAssets() external {
        // Let half of inventory (25) be sold
        uint256 price = auction.currentPrice();
        vm.deal(buyer1, price * 25);
        vm.prank(buyer1);
        auction.buy{value: price * 25}(25); // Overpay to be safe

        // warp to end => time is up
        vm.warp(startTime + duration + 1);

        // seller withdraws 25 unsold items
        vm.prank(seller);
        vm.expectEmit();
        emit DutchAuction.UnsoldAssetsWithdrawn(seller, 25);
        auction.withdrawUnsoldAssets();

        // mock sets inventory to 0 & unsoldWithdrawn = true
        assertEq(auction.getInventory(), 0, "inventory should be 0 after withdraw");
        assertTrue(auction.unsoldWithdrawn(), "unsoldWithdrawn should be true");
    }

    function test_withdrawUnsoldAssets_RevertWhen_AuctionNotEnded() external {
        // warp to half time and buy 1 item
        vm.warp(startTime + (duration / 2));
        vm.prank(buyer1);
        auction.buy{value: auction.currentPrice()}(1);

        vm.expectRevert(DutchAuction.AuctionNotEnded.selector);
        auction.withdrawUnsoldAssets();
    }

    function test_withdrawUnsoldAssets_RevertWhen_NoUnsoldAssets() external {
        // buyer1 buys entire inventory
        uint256 price = auction.currentPrice();
        vm.deal(buyer1, price * inventory);
        vm.prank(buyer1);
        auction.buy{value: price * inventory}(inventory);

        // now inventory=0 => revert
        vm.expectRevert(DutchAuction.NoUnsoldAssetsToWithdraw.selector);
        auction.withdrawUnsoldAssets();
    }
}