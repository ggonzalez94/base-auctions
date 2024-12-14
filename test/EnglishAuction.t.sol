// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {EnglishAuction} from "../src/EnglishAuction.sol";

////////////////////////////////////////////////////////////
// Mock Implementations
////////////////////////////////////////////////////////////

contract MockEnglishAuction is EnglishAuction {
    address public winnerAssetRecipient;

    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod
    ) EnglishAuction(_seller, _reservePrice, _duration, _extensionThreshold, _extensionPeriod) {}

    function _transferAssetToWinner(address winner) internal override {
        winnerAssetRecipient = winner;
    }
}

// Mock to test anti-sniping
contract MockEnglishAuctionWithIncrement is MockEnglishAuction {
    uint256 public incrementRatio; // e.g. at least 10% higher than current bid

    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod,
        uint256 _incrementRatio
    ) MockEnglishAuction(_seller, _reservePrice, _duration, _extensionThreshold, _extensionPeriod) {
        incrementRatio = _incrementRatio; // 10 means 10% increments required
    }

    function _validateBidIncrement(uint256 newBid) internal view override {
        uint256 currentHighest = getHighestBid();
        if (newBid <= currentHighest) {
            revert BidNotHighEnough(newBid, currentHighest);
        }
        uint256 requiredIncrement = (currentHighest * incrementRatio) / 100;
        if (newBid < currentHighest + requiredIncrement) {
            revert BidNotHighEnough(newBid, currentHighest + requiredIncrement);
        }
    }
}

////////////////////////////////////////////////////////////
// Test Contract
////////////////////////////////////////////////////////////

contract EnglishAuctionTest is Test {
    address seller = address(0xA1);
    address bidder1 = address(0xB1);
    address bidder2 = address(0xB2);
    address randomUser = address(0xC1);

    uint256 reservePrice = 1 ether;
    uint256 duration = 1 days;
    uint256 extensionThreshold = 300; // 5 minutes
    uint256 extensionPeriod = 600; // 10 minutes

    MockEnglishAuction auction;

    function setUp() external {
        // Warp to a known start time for consistent testing
        vm.warp(1000);
        auction = new MockEnglishAuction(seller, reservePrice, duration, extensionThreshold, extensionPeriod);

        vm.deal(bidder1, 10 ether);
        vm.deal(bidder2, 10 ether);
        vm.deal(seller, 0); // seller starts with zero for clarity
        vm.deal(randomUser, 1 ether);
    }

    //////////////////////////
    // Initialization Tests //
    //////////////////////////

    function test_setUpState() external {
        assertEq(auction.getHighestBid(), reservePrice, "Initial highest bid should match reserve price");
        uint256 expectedEndTime = block.timestamp + duration;
        assertEq(auction.getEndTime(), expectedEndTime, "End time should be start + duration");
        assertEq(auction.getHighestBidder(), address(0), "No highest bidder initially");
        assertEq(auction.isFinalized(), false, "Auction should not be finalized initially");
    }

    //////////////////////////
    // Bidding Tests        //
    //////////////////////////

    function test_placeBidUpdatesHighestBid() external {
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();
        vm.stopPrank();

        assertEq(auction.getHighestBid(), 2 ether, "Highest bid should update");
        assertEq(auction.getHighestBidder(), bidder1, "Highest bidder should update");
    }

    function test_placeBid_RevertWhen_BidBelowOrEqualReservePrice() external {
        vm.startPrank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.BidNotHighEnough.selector, 1 ether, 1 ether));
        auction.placeBid{value: 1 ether}();
        vm.stopPrank();
    }

    function test_placeBid_RevertWhen_BidNotHigherThanCurrent() external {
        // First valid bid
        vm.prank(bidder1);
        auction.placeBid{value: 3 ether}();

        // Second bid tries equal or lower
        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.BidNotHighEnough.selector, 2 ether, 3 ether));
        auction.placeBid{value: 2 ether}();
    }

    function test_placeBid_RevertWhen_AuctionEnded() external {
        vm.warp(block.timestamp + duration + 1);
        vm.prank(bidder1);
        vm.expectRevert(EnglishAuction.AuctionEnded.selector);
        auction.placeBid{value: 2 ether}();
    }

    //////////////////////////
    // Refund & Withdrawal  //
    //////////////////////////

    function test_withdrawRefund_Works() external {
        // bidder1 makes first bid
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();
        vm.stopPrank();

        // bidder2 outbids bidder1
        vm.startPrank(bidder2);
        auction.placeBid{value: 3 ether}();
        vm.stopPrank();

        // bidder1 should have a refund available
        uint256 bidder1BalanceBefore = bidder1.balance;
        vm.startPrank(bidder1);
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = bidder1.balance;

        assertEq(bidder1BalanceAfter, bidder1BalanceBefore + 2 ether, "Bidder1 should be refunded");
    }

    function test_withdrawRefund_OnlyIncludesLosingBids() external {
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.prank(bidder2);
        auction.placeBid{value: 3 ether}();

        vm.startPrank(bidder1);
        auction.placeBid{value: 4 ether}();

        // bidder1 should only get refunded for their losing bid
        // not for the second bid(which is the highest bid currently)
        // A future optimization could allow existing bidders to use funds they already hold in the contract for future bids
        uint256 bidder1BalanceBefore = bidder1.balance;
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = bidder1.balance;

        assertEq(
            bidder1BalanceAfter, bidder1BalanceBefore + 2 ether, "Bidder1 should be refunded with only their losing bid"
        );
    }

    function test_withdrawRefund_RevertWhen_NoRefundForCaller() external {
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.NoRefundAvailable.selector, randomUser));
        vm.prank(randomUser);
        auction.withdrawRefund();
    }

    function test_withdrawRefund_RevertWhen_CurrentHighestBidder() external {
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.NoRefundAvailable.selector, bidder1));
        auction.withdrawRefund();
    }

    function test_withdrawSellerProceeds_Works() external {
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.startPrank(seller);
        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        uint256 sellerBalanceBefore = seller.balance;
        auction.withdrawSellerProceeds();
        uint256 sellerBalanceAfter = seller.balance;

        assertEq(sellerBalanceAfter, sellerBalanceBefore + 2 ether, "Seller should receive funds");
    }

    function test_withdrawSellerProceeds_RevertWhen_NoProceedsAvailable() external {
        vm.startPrank(seller);
        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        vm.expectRevert(EnglishAuction.NoProceedsAvailable.selector);
        auction.withdrawSellerProceeds();
    }

    function test_withdrawSellerProceeds_RevertWhen_AuctionNotFinalized() external {
        vm.startPrank(seller);
        vm.expectRevert(EnglishAuction.AuctionNotYetFinalized.selector);
        auction.withdrawSellerProceeds();
    }

    function test_withdrawSellerProceeds_RevertWhen_CallerIsNotSeller() external {
        vm.startPrank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.OnlySellerCanCall.selector, bidder1));
        auction.withdrawSellerProceeds();
    }

    // //////////////////////////
    // // Auction End Behavior //
    // //////////////////////////

    // function test_placeBid_RevertWhen_AuctionEnded() external {
    //     // Fast-forward to after the auction ends
    //     vm.warp(block.timestamp + duration + 1);

    //     vm.startPrank(bidder1);
    //     vm.expectRevert(EnglishAuction.AuctionEnded.selector);
    //     auction.placeBid{value: 2 ether}();
    //     vm.stopPrank();
    // }

    // function test_finalizeAuctionTransfersFundsAndAssetsWithWinner() external {
    //     // Bidder1 places a bid
    //     vm.prank(bidder1);
    //     auction.placeBid{value: 2 ether}();

    //     // Move past end
    //     vm.warp(block.timestamp + duration + 1);

    //     uint256 sellerBalanceBefore = seller.balance;
    //     auction.finalizeAuction();
    //     uint256 sellerBalanceAfter = seller.balance;

    //     assertEq(sellerBalanceAfter, sellerBalanceBefore + 2 ether, "Seller should receive funds");
    //     assertEq(auction.winnerAssetRecipient(), bidder1, "Winner should receive the asset");
    // }

    // function test_finalizeAuction_RevertWhen_AuctionNotYetEnded() external {
    //     vm.prank(bidder1);
    //     auction.placeBid{value: 2 ether}();

    //     vm.expectRevert(EnglishAuction.AuctionNotYetEnded.selector);
    //     auction.finalizeAuction();
    // }

    // function test_finalizeAuctionWorksWithNoBids() external {
    //     // No one bids, just end the auction
    //     vm.warp(block.timestamp + duration + 1);

    //     // finalize
    //     auction.finalizeAuction();

    //     // Seller gets nothing, no winner
    //     // Just ensuring no revert and no changes
    //     assertEq(auction.winnerAssetRecipient(), address(0), "No winner if no bids");
    //     // Seller had no funds, should remain with no increase
    //     assertEq(seller.balance, 0, "Seller gets no funds if no bids");
    // }

    // function test_finalizeAuction_RevertWhen_AlreadyFinalized() external {
    //     vm.prank(bidder1);
    //     auction.placeBid{value: 2 ether}();

    //     vm.warp(block.timestamp + duration + 1);
    //     auction.finalizeAuction();

    //     vm.expectRevert(EnglishAuction.AuctionAlreadyFinalized.selector);
    //     auction.finalizeAuction();
    // }

    // //////////////////////////
    // // Anti-Sniping Tests   //
    // //////////////////////////

    // function test_placeBidExtendsAuctionNearEnd() external {
    //     // Move close to the end
    //     vm.warp(block.timestamp + duration - (extensionThreshold - 1));

    //     // Place a bid to trigger extension
    //     vm.prank(bidder1);
    //     auction.placeBid{value: 2 ether}();

    //     uint256 newEndTime = auction.getEndTime();
    //     uint256 expectedEndTime = block.timestamp + extensionPeriod;
    //     assertEq(newEndTime, expectedEndTime, "Should extend the auction end time");
    // }

    // function test_placeBidDoesNotExtendWhenNotWithinThreshold() external {
    //     // Warp well before threshold
    //     vm.warp(block.timestamp + duration - extensionThreshold - 1000);

    //     // Place a bid
    //     vm.prank(bidder1);
    //     auction.placeBid{value: 2 ether}();

    //     // Should not extend
    //     uint256 endTimeAfter = auction.getEndTime();
    //     assertEq(endTimeAfter, 1000 + duration, "No extension should occur");
    // }

    // function test_noExtensionIfThresholdIsZero() external {
    //     // Deploy a new auction with zero threshold
    //     MockEnglishAuction noExtendAuction = new MockEnglishAuction(seller, reservePrice, duration, 0, extensionPeriod);

    //     vm.deal(bidder1, 5 ether);
    //     // Warp close to end
    //     vm.warp(block.timestamp + duration - 1);

    //     vm.prank(bidder1);
    //     noExtendAuction.placeBid{value: 2 ether}();

    //     // Check no extension
    //     uint256 endTimeAfter = noExtendAuction.getEndTime();
    //     assertEq(endTimeAfter, 1000 + duration, "No extension if threshold is zero");
    // }

    // //////////////////////////
    // // Increment Tests      //
    // //////////////////////////

    // function test_placeBidWithIncrementRequirement() external {
    //     // Deploy auction with increments (e.g. 10% increment)
    //     MockEnglishAuctionWithIncrement incrementAuction = new MockEnglishAuctionWithIncrement(
    //         seller,
    //         reservePrice,
    //         duration,
    //         extensionThreshold,
    //         extensionPeriod,
    //         10 // 10% increment
    //     );
    //     vm.deal(bidder1, 10 ether);
    //     vm.deal(bidder2, 10 ether);

    //     // Bidder1 places a bid of 2 ether (reserve: 1 ether, 2 is valid)
    //     vm.prank(bidder1);
    //     incrementAuction.placeBid{value: 2 ether}();

    //     // Bidder2 tries to outbid with only 2.1 ether (less than 10% increment over 2 ether)
    //     // 10% of 2 ether is 0.2 ether, so must be at least 2.2 ether
    //     vm.prank(bidder2);
    //     vm.expectRevert(abi.encodeWithSelector(EnglishAuction.BidNotHighEnough.selector, 2.1 ether, 2.2 ether));
    //     incrementAuction.placeBid{value: 2.1 ether}();

    //     // Bidder2 places a valid bid (2.5 ether meets 10% increment)
    //     vm.prank(bidder2);
    //     incrementAuction.placeBid{value: 2.5 ether}();

    //     assertEq(incrementAuction.getHighestBidder(), bidder2, "Bidder2 should now be highest bidder");
    //     assertEq(incrementAuction.getHighestBid(), 2.5 ether, "Highest bid should be updated");
    // }

    // //////////////////////////
    // // OnlySeller Tests     //
    // //////////////////////////

    // function test_sellerOnlyFunction_RevertWhen_CallerIsNotSeller() external {
    //     vm.prank(bidder1);
    //     vm.expectRevert(abi.encodeWithSelector(EnglishAuction.OnlySellerCanCall.selector, bidder1));
    //     auction.sellerOnlyFunction();
    // }

    // function test_sellerOnlyFunctionSucceedsWhenCalledBySeller() external {
    //     vm.prank(seller);
    //     auction.sellerOnlyFunction();
    //     // No revert means success
    // }

    // //////////////////////////
    // // Finalization Edge    //
    // //////////////////////////

    // function test_finalizeWhenNoBids() external {
    //     // No bids were placed
    //     vm.warp(block.timestamp + duration + 1);
    //     auction.finalizeAuction();

    //     assertEq(auction.winnerAssetRecipient(), address(0), "No winner if no bids");
    //     assertEq(seller.balance, 0, "No funds for seller if no bids");
    // }

    // function test_finalizeAfterEndedWithBidsWorksMultipleTimes_RevertSecondTime() external {
    //     vm.prank(bidder1);
    //     auction.placeBid{value: 2 ether}();

    //     vm.warp(block.timestamp + duration + 1);
    //     auction.finalizeAuction();

    //     // Trying to finalize again should revert
    //     vm.expectRevert(EnglishAuction.AuctionAlreadyFinalized.selector);
    //     auction.finalizeAuction();
    // }

    // function test_finalizeImmediatelyAfterEndWithNoExtension() external {
    //     // Deploy a new auction with no extension
    //     MockEnglishAuction noExtend = new MockEnglishAuction(
    //         seller,
    //         reservePrice,
    //         duration,
    //         0,
    //         0 // no extension
    //     );
    //     vm.deal(bidder1, 5 ether);
    //     vm.prank(bidder1);
    //     noExtend.placeBid{value: 2 ether}();

    //     vm.warp(block.timestamp + duration + 1);
    //     noExtend.finalizeAuction();

    //     assertEq(noExtend.winnerAssetRecipient(), bidder1, "Bidder1 should win");
    //     assertEq(seller.balance, 2 ether, "Seller should receive funds");
    // }
}
