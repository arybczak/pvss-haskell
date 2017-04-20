-- Implementation of SCRAPE - in DDH
--
--	<http://eprint.iacr.org/2017/216>
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Crypto.SCRAPE.DDH
    (
    -- * Simple alias
      Threshold
    , ShareId
    , ExtraGen
    , Point
    , DLEQ.Proof
    , Scalar
    , Secret
    , Participants(..)
    , PublicKey(..)
    , PrivateKey(..)
    , KeyPair(..)
    , DhSecret(..)
    -- * Types
    , Escrow(..)
    , Commitment
    , DecryptedShare(..)
    -- * method
    , escrow
    , escrowWith
    , escrowNew
    , shareDecrypt
    , verifyEncryptedShares
    , verifyDecryptedShare
    , verifySecret
    , recover
    , secretToDhSecret
    , reorderDecryptShares
    -- * temporary export to get testing
    , keyPairGenerate
    ) where

import           Control.DeepSeq
import           Control.Monad

import           GHC.Generics

import           Data.Binary
import qualified Data.Vector            as V

import qualified Crypto.PVSS.DLEQ       as DLEQ
import           Crypto.PVSS.ECC
import           Crypto.PVSS.Polynomial (Polynomial (..))
import qualified Crypto.PVSS.Polynomial as Polynomial
import           Crypto.Random

newtype Commitment = Commitment { unCommitment :: Point }
    deriving (Show,Eq,NFData,Binary)

-- | The number of shares needed to reconstitute the secret.
--
-- When the threshold is reached, as in the number of decrypted
-- shares is equal or more than the threshold, the secret should
-- be recoverable through the protocol
type Threshold = Integer

-- | The ID associated with a share
type ShareId = Integer

-- | Extra generator
newtype ExtraGen = ExtraGen Point
    deriving (Show,Eq,NFData,Binary)

-- | Secret
newtype Secret = Secret Point
    deriving (Show,Eq,NFData,Binary)

-- | Transform a secret into a usable random value
secretToDhSecret :: Secret -> DhSecret
secretToDhSecret (Secret p) = pointToDhSecret p

-- | i'th share value
newtype Si = Si Scalar

-- | Encrypted i'th share value with i'th public key
newtype EncryptedSi = EncryptedSi Point
    deriving (Show,Eq,Generic,NFData,Binary)

-- | An decrypted share decrypted by a party's key and
data DecryptedShare = DecryptedShare
    { shareDecryptedVal   :: !Point      -- ^ decrypted share
    , decryptedValidProof :: !DLEQ.Proof -- ^ proof the decryption is valid
    } deriving (Show,Eq,Generic)

instance NFData DecryptedShare
instance Binary DecryptedShare where
    get = DecryptedShare <$> get <*> get
    put (DecryptedShare val proof) = put val >> put proof

data Escrow = Escrow
    { escrowExtraGen   :: !ExtraGen
    , escrowPolynomial :: !Polynomial
    , escrowSecret     :: !Secret
    , escrowProof      :: !DLEQ.Proof
    } deriving (Show,Eq,Generic)

instance NFData Escrow

-- | This is a list of participants in one instance of SCRAPE
--
-- The list has a specific *order*, and the order is important to
-- be kept between various calls in this protocol.
newtype Participants = Participants [PublicKey]
    deriving (Show,Eq,Generic)

instance NFData Participants
instance Binary Participants

-- | Prepare a new escrowing context
--
-- The only needed parameter is the threshold
-- do not re-use an escrow context for different context.
escrowNew :: MonadRandom randomly
          => Threshold
          -> randomly Escrow
escrowNew threshold = do
    poly <- Polynomial.generate (fromIntegral (threshold - 1))
    gen  <- pointFromSecret <$> keyGenerate

    let secret = Polynomial.atZero poly
        gS     = pointFromSecret secret
    challenge <- keyGenerate
    let dleq  = DLEQ.DLEQ { DLEQ.dleq_g1 = curveGenerator, DLEQ.dleq_h1 = gS, DLEQ.dleq_g2 = gen, DLEQ.dleq_h2 = gen .* secret }
        proof = DLEQ.generate challenge secret dleq

    return $ Escrow
        { escrowExtraGen   = ExtraGen gen
        , escrowPolynomial = poly
        , escrowSecret     = Secret gS
        , escrowProof      = proof
        }

-- | Prepare a secret into public encrypted shares for distributions using the PVSS scheme
--
-- returns:
--  * the encrypted secret
--  * the list of public commitments to the scheme
--  * The encrypted shares that should be distributed to each partipants.
escrow :: MonadRandom randomly
       => Threshold    -- ^ PVSS scheme configuration n/t threshold
       -> Participants -- ^ Participants public keys
       -> randomly (ExtraGen, Secret, [EncryptedSi], [Commitment], DLEQ.ParallelProofs)
escrow t pubs = do
    e <- escrowNew t
    (eshares, commitments, proofs) <- escrowWith e pubs
    return (escrowExtraGen e, escrowSecret e, eshares, commitments, proofs)

-- | Escrow with a given polynomial
escrowWith :: MonadRandom randomly
           => Escrow
           -> Participants    -- ^ Participants public keys
           -> randomly ([EncryptedSi], [Commitment], DLEQ.ParallelProofs)
escrowWith escrowParams (Participants pubs) = do
    ws <- replicateM n keyGenerate
    let sis  = map (Si . Polynomial.evaluate (escrowPolynomial escrowParams) . keyFromNum) indexes
        esis = map (uncurry encryptSi) $ zip pubs sis
        vis  = map makeVi sis
        proofParams = zipWith6 makeParallelProofParam indexes pubs vis sis esis ws
        parallelProofs = DLEQ.generateParallel proofParams
    return (esis, vis, parallelProofs)
  where
    indexes :: [Integer]
    indexes = [1..fromIntegral n]
    n       = length pubs
    ExtraGen g = escrowExtraGen escrowParams
    makeVi (Si s) = Commitment (g .* s)
    encryptSi (PublicKey p) (Si s) = EncryptedSi (p .* s)

    makeParallelProofParam _ (PublicKey pub) (Commitment vi) (Si si) (EncryptedSi esi) w =
        let dleq = DLEQ.DLEQ { DLEQ.dleq_g1 = g, DLEQ.dleq_h1 = vi, DLEQ.dleq_g2 = pub, DLEQ.dleq_h2 = esi }
         in (w, si, dleq)

    -- TODO clean this up
    zipWith6 f (u1:us) (v1:vs) (w1:ws) (x1:xs) (y1:ys) (z1:zs) = f u1 v1 w1 x1 y1 z1 : zipWith6 f us vs ws xs ys zs
    zipWith6 _ []      []      []      []      []      []      = []
    zipWith6 _ _       _       _       _       _       _       = error "zipWith6: internal error should have same length"

-- | Decrypt an Encrypted share using the party's key pair.
-- Doesn't verify if an encrypted share is valid, for this
-- you need to use 'verifyEncryptedShare'
--
-- 1) compute Si = Yi ^ (1/xi) = G^(p(i))
-- 2) create a proof of the valid decryption
shareDecrypt :: MonadRandom randomly
             => KeyPair
             -> EncryptedSi
             -> randomly DecryptedShare
shareDecrypt (KeyPair (PrivateKey xi) (PublicKey yi)) (EncryptedSi _Yi) = do
    challenge <- keyGenerate
    let dleq  = DLEQ.DLEQ curveGenerator yi si _Yi
        proof = DLEQ.generate challenge xi dleq
    return $ DecryptedShare si proof
  where xiInv = keyInverse xi
        si    = _Yi .* xiInv

verifyEncryptedShares :: MonadRandom randomly
                      => ExtraGen
                      -> Threshold
                      -> [Commitment]
                      -> DLEQ.ParallelProofs
                      -> [EncryptedSi]
                      -> Participants
                      -> randomly Bool
verifyEncryptedShares (ExtraGen g) t commitments proofs encryptedShares (Participants pubs) = do
    if DLEQ.verifyParallel dleqs proofs
        then rdCheck
        else return False
  where
    !n = fromIntegral $ length pubs
    indexes = [1..n]
    dleqs = zipWith3 makeDLEQ commitments pubs encryptedShares
    makeDLEQ (Commitment vi) (PublicKey pki) (EncryptedSi esi) =
        DLEQ.DLEQ g vi pki esi
    rdCheck = do
        poly <- Polynomial.generate (fromIntegral $ n - t - 1) -- hardcoded
        let cPerp = for indexes $ \evalPoint ->
                        vi evalPoint #* Polynomial.evaluate poly (keyFromNum evalPoint)
        let v = mulAndSum $ zipWith (\(Commitment c) cip -> (c,cip)) commitments cPerp
        return $ v == pointIdentity
      where
        for = flip map
        vi i = foldl1 (#*)
             $ for ((\j -> j /= i) `filter` indexes) $ \j -> keyInverse (keyFromNum i #- keyFromNum j)

-- | Verify a decrypted share against the public key and the encrypted share
verifyDecryptedShare :: (EncryptedSi, PublicKey, DecryptedShare)
                     -> Bool
verifyDecryptedShare (EncryptedSi eshare,PublicKey pub,share) =
    DLEQ.verify dleq (decryptedValidProof share)
  where dleq = DLEQ.DLEQ curveGenerator pub (shareDecryptedVal share) eshare

-- | Verify that a secret recovered is the one escrow
verifySecret :: ExtraGen
             -> [Commitment]
             -> Secret
             -> DLEQ.Proof
             -> Bool
verifySecret (ExtraGen gen) commitments (Secret secret) proof =
    DLEQ.verify dleq proof
  where dleq = DLEQ.DLEQ
            { DLEQ.dleq_g1 = curveGenerator
            , DLEQ.dleq_h1 = secret
            , DLEQ.dleq_g2 = gen
            , DLEQ.dleq_h2 = unCommitment (commitments !! 0)
            }

reorderDecryptShares :: Participants
                     -> [(PublicKey, DecryptedShare)] -- the list of participant decrypted share identified by a public key
                     -> Maybe [(ShareId, DecryptedShare)]
reorderDecryptShares (Participants participants) shares =
    sequence $ map indexSharesByParticipants shares
  where
    idxParticipants = zip participants [1..]
    indexSharesByParticipants (pub, dshare) =
        case lookup pub idxParticipants of
            Nothing -> Nothing
            Just i  -> Just (i, dshare)

-- | Recover the DhSecret used
--
-- Need to pass the correct amount of shares (threshold),
-- preferably from a 'getValidRecoveryShares' call
recover :: [(ShareId, DecryptedShare)] -- the list of participant decrypted share identified by a public key
        -> Secret
recover shares = Secret $ V.ifoldl' interpolate pointIdentity vshares
  where
    vshares = V.fromList shares
    t = fromIntegral $ length shares

    interpolate :: Point -> Int -> (Integer, DecryptedShare) -> Point
    interpolate result sid share = result .+ (shareDecryptedVal (snd share) .* value)
      where
        value = calc 0 (keyFromNum 1)
        calc :: Int -> Scalar -> Scalar
        calc j !acc
            | j == t       = acc
            | j == sid     = calc (j+1) acc
            | otherwise    =
                let sj   = fst (vshares V.! j)
                    si   = fst (vshares V.! sid)
                    dinv = keyInverse (keyFromNum sj #- keyFromNum si)
                    e    = keyFromNum sj #* dinv
                 in calc (j+1) (acc #* e)
