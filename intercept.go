package main

import (
	"bytes"
	"fmt"
	"log"
	"math/big"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/wire"
	sphinx "github.com/lightningnetwork/lightning-onion"
	"github.com/lightningnetwork/lnd/lnwire"
	"github.com/lightningnetwork/lnd/record"
	"github.com/lightningnetwork/lnd/routing/route"
)

type interceptAction int

const (
	INTERCEPT_RESUME              interceptAction = 0
	INTERCEPT_RESUME_OR_CANCEL    interceptAction = 1
	INTERCEPT_FAIL_HTLC           interceptAction = 2
	INTERCEPT_FAIL_HTLC_WITH_CODE interceptAction = 3
)

type interceptFailureCode uint16

var (
	FAILURE_TEMPORARY_CHANNEL_FAILURE            interceptFailureCode = 0x1007
	FAILURE_INCORRECT_OR_UNKNOWN_PAYMENT_DETAILS interceptFailureCode = 0x4015
)

type interceptResult struct {
	action       interceptAction
	failureCode  interceptFailureCode
	destination  []byte
	amountMsat   uint64
	channelPoint *wire.OutPoint
	onionBlob    []byte
}

func intercept(reqPaymentHash []byte, reqOutgoingAmountMsat uint64, reqOutgoingExpiry uint32) interceptResult {
	paymentHash, paymentSecret, destination, incomingAmountMsat, outgoingAmountMsat, channelPoint, err := paymentInfo(reqPaymentHash)
	if err != nil {
		log.Printf("paymentInfo(%x) error: %v", reqPaymentHash, err)
		return interceptResult{
			action: INTERCEPT_FAIL_HTLC,
		}
	}
	log.Printf("paymentHash:%x\npaymentSecret:%x\ndestination:%x\nincomingAmountMsat:%v\noutgoingAmountMsat:%v\n\n",
		paymentHash, paymentSecret, destination, incomingAmountMsat, outgoingAmountMsat)
	if paymentSecret != nil {

		if channelPoint == nil {
			if bytes.Equal(paymentHash, reqPaymentHash) {
				channelPoint, err = openChannel(client, reqPaymentHash, destination, incomingAmountMsat)
				log.Printf("openChannel(%x, %v) err: %v", destination, incomingAmountMsat, err)
				if err != nil {
					return interceptResult{
						action: INTERCEPT_FAIL_HTLC,
					}
				}
			} else { //probing
				failureCode := FAILURE_TEMPORARY_CHANNEL_FAILURE
				isConnected, _ := client.IsConnected(destination)
				if err != nil || !*isConnected {
					failureCode = FAILURE_INCORRECT_OR_UNKNOWN_PAYMENT_DETAILS
				}

				return interceptResult{
					action:      INTERCEPT_FAIL_HTLC_WITH_CODE,
					failureCode: failureCode,
				}
			}
		}

		pubKey, err := btcec.ParsePubKey(destination)
		if err != nil {
			log.Printf("btcec.ParsePubKey(%x): %v", destination, err)
			return interceptResult{
				action: INTERCEPT_FAIL_HTLC,
			}
		}

		sessionKey, err := btcec.NewPrivateKey()
		if err != nil {
			log.Printf("btcec.NewPrivateKey(): %v", err)
			return interceptResult{
				action: INTERCEPT_FAIL_HTLC,
			}
		}

		var bigProd, bigAmt big.Int
		amt := (bigAmt.Div(bigProd.Mul(big.NewInt(outgoingAmountMsat), big.NewInt(int64(reqOutgoingAmountMsat))), big.NewInt(incomingAmountMsat))).Int64()

		var addr [32]byte
		copy(addr[:], paymentSecret)
		hop := route.Hop{
			AmtToForward:     lnwire.MilliSatoshi(amt),
			OutgoingTimeLock: reqOutgoingExpiry,
			MPP:              record.NewMPP(lnwire.MilliSatoshi(outgoingAmountMsat), addr),
			CustomRecords:    make(record.CustomSet),
		}

		var b bytes.Buffer
		err = hop.PackHopPayload(&b, uint64(0))
		if err != nil {
			log.Printf("hop.PackHopPayload(): %v", err)
			return interceptResult{
				action: INTERCEPT_FAIL_HTLC,
			}
		}

		payload, err := sphinx.NewHopPayload(nil, b.Bytes())
		if err != nil {
			log.Printf("sphinx.NewHopPayload(): %v", err)
			return interceptResult{
				action: INTERCEPT_FAIL_HTLC,
			}
		}

		var sphinxPath sphinx.PaymentPath
		sphinxPath[0] = sphinx.OnionHop{
			NodePub:    *pubKey,
			HopPayload: payload,
		}
		sphinxPacket, err := sphinx.NewOnionPacket(
			&sphinxPath, sessionKey, reqPaymentHash,
			sphinx.DeterministicPacketFiller,
		)
		if err != nil {
			log.Printf("sphinx.NewOnionPacket(): %v", err)
			return interceptResult{
				action: INTERCEPT_FAIL_HTLC,
			}
		}
		var onionBlob bytes.Buffer
		err = sphinxPacket.Encode(&onionBlob)
		if err != nil {
			log.Printf("sphinxPacket.Encode(): %v", err)
			return interceptResult{
				action: INTERCEPT_FAIL_HTLC,
			}
		}

		return interceptResult{
			action:       INTERCEPT_RESUME_OR_CANCEL,
			destination:  destination,
			channelPoint: channelPoint,
			amountMsat:   uint64(amt),
			onionBlob:    onionBlob.Bytes(),
		}
	} else {
		return interceptResult{
			action: INTERCEPT_RESUME,
		}
	}
}
func checkPayment(incomingAmountMsat, outgoingAmountMsat int64) error {
	fees := incomingAmountMsat * channelFeePermyriad / 10_000 / 1_000 * 1_000
	if fees < channelMinimumFeeMsat {
		fees = channelMinimumFeeMsat
	}
	if incomingAmountMsat-outgoingAmountMsat < fees {
		return fmt.Errorf("not enough fees")
	}
	return nil
}

func openChannel(client LightningClient, paymentHash, destination []byte, incomingAmountMsat int64) (*wire.OutPoint, error) {
	capacity := incomingAmountMsat/1000 + additionalChannelCapacity
	if capacity == publicChannelAmount {
		capacity++
	}
	channelPoint, err := client.OpenChannel(&OpenChannelRequest{
		Destination: destination,
		CapacitySat: uint64(capacity),
		TargetConf:  6,
		IsPrivate:   true,
		IsZeroConf:  true,
	})
	if err != nil {
		log.Printf("client.OpenChannelSync(%x, %v) error: %v", destination, capacity, err)
		return nil, err
	}
	sendOpenChannelEmailNotification(
		paymentHash,
		incomingAmountMsat,
		destination,
		capacity,
		channelPoint.String(),
	)
	err = setFundingTx(paymentHash, channelPoint)
	return channelPoint, err
}
