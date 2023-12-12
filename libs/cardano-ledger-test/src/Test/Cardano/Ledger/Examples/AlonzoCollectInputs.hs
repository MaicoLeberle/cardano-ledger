{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Test.Cardano.Ledger.Examples.AlonzoCollectInputs (tests) where

import Cardano.Ledger.Alonzo (Alonzo)
import Cardano.Ledger.Alonzo.Plutus.Context (mkPlutusScriptContext)
import Cardano.Ledger.Alonzo.Plutus.Evaluate (CollectError (..), collectPlutusScriptsWithContext)
import Cardano.Ledger.Alonzo.Plutus.TxInfo
import Cardano.Ledger.Alonzo.Scripts (AlonzoEraScript (..), AlonzoScript (..), ExUnits (..))
import qualified Cardano.Ledger.Alonzo.Scripts as Tag (Tag (..))
import Cardano.Ledger.Alonzo.Tx (
  ScriptPurpose (..),
 )
import Cardano.Ledger.Alonzo.TxWits (RdmrPtr (..), Redeemers (..))
import Cardano.Ledger.BaseTypes (ProtVer (..), natVersion)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core
import Cardano.Ledger.Plutus.Data (Data (..), unData)
import Cardano.Ledger.Plutus.Evaluate (
  PlutusDatums (..),
  PlutusWithContext (..),
 )
import Cardano.Ledger.Plutus.Language (Language (..))
import Cardano.Ledger.Pretty.Babbage ()
import Cardano.Ledger.SafeHash (hashAnnotated)
import Cardano.Ledger.UTxO (UTxO (..))
import Cardano.Ledger.Val (inject)
import Cardano.Slotting.EpochInfo (EpochInfo, fixedEpochInfo)
import Cardano.Slotting.Slot (EpochSize (..))
import Cardano.Slotting.Time (SystemStart (..), mkSlotLength)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Lens.Micro
import qualified PlutusLedgerApi.V1 as PV1
import Test.Cardano.Ledger.Alonzo.CostModel (freeV1CostModels)
import Test.Cardano.Ledger.Core.KeyPair (mkWitnessVKey)
import Test.Cardano.Ledger.Examples.STSTestUtils (
  freeCostModelV1,
  initUTxO,
  mkGenesisTxIn,
  mkTxDats,
  someAddr,
  someKeys,
 )
import Test.Cardano.Ledger.Generic.Fields (
  PParamsField (..),
  TxBodyField (..),
  TxField (..),
  TxOutField (..),
  WitnessesField (..),
 )
import Test.Cardano.Ledger.Generic.PrettyCore ()
import Test.Cardano.Ledger.Generic.Proof
import Test.Cardano.Ledger.Generic.Scriptic (Scriptic (..))
import Test.Cardano.Ledger.Generic.Updaters
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (Assertion, testCase, (@?=))

tests :: TestTree
tests =
  testCase
    "collectTwoPhaseScriptInputs output order"
    collectTwoPhaseScriptInputsOutputOrdering

-- Test for Plutus Data Ordering, using this strategy

-- | Never apply this to any Era but Alonzo or Babbage
collectTwoPhaseScriptInputsOutputOrdering ::
  Assertion
collectTwoPhaseScriptInputsOutputOrdering = do
  collectInputs apf testEpochInfo testSystemStart (pp apf) (validatingTx apf) (initUTxO apf)
    @?= Right
      [ withPlutusScript plutusScript $ \plutus ->
          PlutusWithContext
            { pwcProtocolVersion = pvMajor (pp apf ^. ppProtocolVersionL)
            , pwcScript = Left $ plutus
            , pwcDatums = PlutusDatums [unData @Alonzo datum, unData @Alonzo redeemer, context]
            , pwcExUnits = ExUnits 5000 5000
            , pwcCostModel = freeCostModelV1
            }
      ]
  where
    apf = Alonzo Standard
    plutusScript = case always 3 apf of
      TimelockScript _ -> error "always was not a Plutus script"
      PlutusScript ps -> ps
    scriptPurpose = Spending $ mkGenesisTxIn 1
    Data context =
      either (\err -> error $ "Translation error: " ++ show err) id $
        mkPlutusScriptContext'
          apf
          plutusScript
          scriptPurpose
          (pp apf)
          testEpochInfo
          testSystemStart
          (initUTxO apf)
          (validatingTx apf)

-- ============================== DATA ===============================

datum :: Era era => Data era
datum = Data (PV1.I 123)

redeemer :: Era era => Data era
redeemer = Data (PV1.I 42)

validatingTx ::
  forall era.
  ( Scriptic era
  , EraTx era
  , GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
validatingTx pf =
  newTx
    pf
    [ Body validatingBody
    , WitnessesI
        [ AddrWits' [mkWitnessVKey (hashAnnotated validatingBody) (someKeys pf)]
        , ScriptWits' [always 3 pf]
        , DataWits' [datum]
        , RdmrWits redeemers
        ]
    ]
  where
    validatingBody =
      newTxBody
        pf
        [ Inputs' [mkGenesisTxIn 1]
        , Collateral' [mkGenesisTxIn 11]
        , Outputs' [newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 4995)]]
        , Txfee (Coin 5)
        , WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] redeemers (mkTxDats datum))
        ]
    redeemers =
      Redeemers $
        Map.singleton (RdmrPtr Tag.Spend 0) (redeemer, ExUnits 5000 5000)

-- ============================== Helper functions ===============================

-- We have some tests that use plutus scripts, so they can only be run in
-- Babbage and Alonzo. How do we do that? We identify functions that are
-- only well typed in those Eras, and we make versions which are parameterized
-- by a proof. But which raise an error in other Eras.

collectInputs ::
  forall era.
  Proof era ->
  EpochInfo (Either Text) ->
  SystemStart ->
  PParams era ->
  Tx era ->
  UTxO era ->
  Either [CollectError era] [PlutusWithContext]
collectInputs (Alonzo _) = collectPlutusScriptsWithContext
collectInputs (Babbage _) = collectPlutusScriptsWithContext
collectInputs (Conway _) = collectPlutusScriptsWithContext
collectInputs x = error ("collectInputs Not defined in era " ++ show x)

mkPlutusScriptContext' ::
  Proof era ->
  PlutusScript era ->
  ScriptPurpose era ->
  PParams era ->
  EpochInfo (Either Text) ->
  SystemStart ->
  UTxO era ->
  Tx era ->
  Either (ContextError era) (Data era)
mkPlutusScriptContext' (Alonzo _) = mkPlutusScriptContext
mkPlutusScriptContext' (Babbage _) = mkPlutusScriptContext
mkPlutusScriptContext' (Conway _) = mkPlutusScriptContext
mkPlutusScriptContext' era = error ("mkPlutusScriptContext is not defined in era " ++ show era)

testEpochInfo :: EpochInfo (Either Text)
testEpochInfo = fixedEpochInfo (EpochSize 100) (mkSlotLength 1)

testSystemStart :: SystemStart
testSystemStart = SystemStart $ posixSecondsToUTCTime 0

-- ============================== PParams ===============================

defaultPPs :: [PParamsField era]
defaultPPs =
  [ Costmdls freeV1CostModels
  , MaxValSize 1000000000
  , MaxTxExUnits $ ExUnits 1000000 1000000
  , MaxBlockExUnits $ ExUnits 1000000 1000000
  , ProtocolVersion $ ProtVer (natVersion @5) 0
  , CollateralPercentage 100
  ]

pp :: EraPParams era => Proof era -> PParams era
pp pf = newPParams pf defaultPPs
