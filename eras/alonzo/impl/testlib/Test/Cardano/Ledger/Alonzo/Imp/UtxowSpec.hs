{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Test.Cardano.Ledger.Alonzo.Imp.UtxowSpec (spec) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Core (
  AlonzoEraTxWits (..),
  scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Alonzo.Plutus.Evaluate (CollectError (..))
import Cardano.Ledger.Alonzo.Rules (AlonzoUtxosPredFailure (..), AlonzoUtxowPredFailure (..))
import Cardano.Ledger.Alonzo.Scripts
import Cardano.Ledger.Alonzo.TxOut (dataHashTxOutL)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), TxDats (..))
import Cardano.Ledger.BaseTypes
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Plutus
import Cardano.Ledger.Shelley.Rules (ShelleyUtxowPredFailure (..))
import qualified Data.Map as Map
import Data.Sequence.Strict (StrictSeq ((:<|)))
import Lens.Micro
import qualified PlutusLedgerApi.Common as P
import Test.Cardano.Ledger.Alonzo.Arbitrary ()
import Test.Cardano.Ledger.Alonzo.ImpTest (AlonzoEraImp, fixupPPHash)
import Test.Cardano.Ledger.Core.Utils (txInAt)
import Test.Cardano.Ledger.Imp.Common
import Test.Cardano.Ledger.Plutus.Examples (guessTheNumber3)
import Test.Cardano.Ledger.Shelley.ImpTest

spec ::
  forall era.
  ( AlonzoEraImp era
  , InjectRuleFailure "LEDGER" ShelleyUtxowPredFailure era
  , InjectRuleFailure "LEDGER" AlonzoUtxowPredFailure era
  , InjectRuleFailure "LEDGER" AlonzoUtxosPredFailure era
  ) =>
  SpecWith (ImpTestState era)
spec = describe "UTXOW" $ do
  let resetAddrWits tx = updateAddrTxWits $ tx & witsTxL . addrTxWitsL .~ []
  let fixupResetAddrWits = fixupPPHash >=> resetAddrWits

  it "MissingRedeemers" $ do
    let lang = eraMaxLanguage @era
    let scriptHash = withSLanguage lang (hashPlutusScript . guessTheNumber3)
    txIn <- produceScript scriptHash
    let missingRedeemer = mkSpendingPurpose $ AsItem txIn
    let tx = mkBasicTx mkBasicTxBody & bodyTxL . inputsTxBodyL .~ [txIn]
    withPostFixup (fixupResetAddrWits . (witsTxL . rdmrsTxWitsL .~ Redeemers mempty)) $
      submitFailingTx
        tx
        [ injectFailure $
            MissingRedeemers [(missingRedeemer, scriptHash)]
        , injectFailure $
            CollectErrors [NoRedeemer missingRedeemer]
        ]

  it "MissingRequiredDatums" $ do
    let lang = eraMaxLanguage @era
    let scriptHash = withSLanguage lang (hashPlutusScript . guessTheNumber3)
    txIn <- produceScript scriptHash
    let tx = mkBasicTx mkBasicTxBody & bodyTxL . inputsTxBodyL .~ [txIn]
    let missingDatum = hashData @era (Data (P.I 3))
    withPostFixup (fixupResetAddrWits . (witsTxL . datsTxWitsL .~ mempty)) $
      submitFailingTx
        tx
        [ injectFailure $
            MissingRequiredDatums [missingDatum] []
        ]

  it "NotAllowedSupplementalDatums" $ do
    let lang = eraMaxLanguage @era
    let scriptHash = withSLanguage lang (hashPlutusScript . guessTheNumber3)
    txIn <- produceScript scriptHash
    let extraDatumHash = hashData @era (Data (P.I 30))
    let extraDatum = Data (P.I 30)
    let tx =
          mkBasicTx mkBasicTxBody
            & bodyTxL . inputsTxBodyL .~ [txIn]
            & witsTxL . datsTxWitsL .~ TxDats (Map.singleton extraDatumHash extraDatum)
    submitFailingTx
      tx
      [ injectFailure $
          NotAllowedSupplementalDatums [extraDatumHash] []
      ]

  it "PPViewHashesDontMatch" $ do
    let lang = eraMaxLanguage @era
    let scriptHash = withSLanguage lang (hashPlutusScript . guessTheNumber3)
    txIn <- produceScript scriptHash
    tx <- fixupTx $ mkBasicTx mkBasicTxBody & bodyTxL . inputsTxBodyL .~ [txIn]

    impAnn "Mismatched " $ do
      wrongIntegrityHash <- arbitrary
      wrongIntegrityHashTx <-
        resetAddrWits $ tx & bodyTxL . scriptIntegrityHashTxBodyL .~ SJust wrongIntegrityHash
      withNoFixup $
        submitFailingTx
          wrongIntegrityHashTx
          [ injectFailure $
              PPViewHashesDontMatch
                (SJust wrongIntegrityHash)
                (tx ^. bodyTxL . scriptIntegrityHashTxBodyL)
          ]
    impAnn "Missing" $ do
      missingIntegrityHashTx <-
        resetAddrWits $ tx & bodyTxL . scriptIntegrityHashTxBodyL .~ SNothing
      withNoFixup $
        submitFailingTx
          missingIntegrityHashTx
          [ injectFailure $
              PPViewHashesDontMatch SNothing (tx ^. bodyTxL . scriptIntegrityHashTxBodyL)
          ]

  it "UnspendableUTxONoDatumHash" $ do
    let lang = eraMaxLanguage @era
    let scriptHash = withSLanguage lang (hashPlutusScript . guessTheNumber3)

    txIn <- impAnn "Produce script at a txout with a missing datahash" $ do
      let addr = Addr Testnet (ScriptHashObj scriptHash) StakeRefNull
      let tx =
            mkBasicTx mkBasicTxBody
              & bodyTxL . outputsTxBodyL .~ [mkBasicTxOut addr (inject (Coin 10))]
      let resetDataHash = dataHashTxOutL .~ SNothing
      let resetTxOutDataHash =
            bodyTxL . outputsTxBodyL
              %~ ( \case
                    h :<| r -> resetDataHash h :<| r
                    _ -> error "Expected non-empty outputs"
                 )

      txInAt (0 :: Int)
        <$> withPostFixup
          (fixupResetAddrWits <$> resetTxOutDataHash)
          (submitTx tx)

    submitFailingTx
      (mkBasicTx mkBasicTxBody & bodyTxL . inputsTxBodyL .~ [txIn])
      [injectFailure $ UnspendableUTxONoDatumHash [txIn]]

  it "ExtraRedeemers" $ do
    let scriptHash = withSLanguage PlutusV1 (hashPlutusScript . guessTheNumber3)
    txIn <- produceScript scriptHash
    let prp = MintingPurpose (AsIx 2)
    dt <- arbitrary
    let tx =
          mkBasicTx mkBasicTxBody
            & bodyTxL . inputsTxBodyL .~ [txIn]
            & witsTxL . rdmrsTxWitsL <>~ Redeemers (Map.singleton prp (dt, ExUnits 0 0))
    let submit = submitFailingTx tx [injectFailure $ ExtraRedeemers [prp]]
    if eraProtVerLow @era < natVersion @9
      then -- PlutusPurpose serialization was fixed in Conway
        withCborRoundTripFailures submit
      else submit
