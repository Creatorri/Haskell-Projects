{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE InstanceSigs #-}

module Economics.Agent
	(Money
	,Mass
	,Amount
	,Identifier
	,Tradable
	,Transaction(Transaction)
	,Bid(Bid)
	,Agent
	--,ClearingHouse
	) where

import Control.Monad.Random
import System.Random
import Data.List
import Data.Maybe
import Data.Either

type Money  = Double
type Mass   = Double
type Amount = Int
type Identifier = Int

class (Eq a) => Tradable a where
        unit_mass :: a -> Mass
	recipes :: a -> [([(a,Amount)],Rand g [(a,Amount)])]

data Transaction t = forall t . (Tradable t) => Transaction { seller :: Identifier
                                                 , buyer :: Identifier
                                                 , item :: t
                                                 , quantity :: Amount
                                                 , unit_price :: Money
                                                 }

data Bid t = forall t . (Tradable t) => Bid { bidder :: Identifier
				 , thing :: t
				 , number :: Amount
				 , cost :: Money
				 }

adjust :: Eq k => (v -> v) -> k -> [(k,v)] -> [(k,v)]
adjust f k [] = []
adjust f k ((k1,v1):ms) = if k == k1 then (k1,f v1):ms else (k1,v1):(adjust f k ms)

thingf :: Rand g Money -> Amount -> Rand g Money
thingf rm am = fmap (\x -> x * (fromIntegral am)) rm

recSide :: (t -> Rand g Money) -> [(t,Amount)] -> Rand g Money
recSide est thing = fmap sum (mapM (\(t,am) -> thingf (est t) am) thing)

recVal :: (t -> Rand g Money) -> ([(t,Amount)],[(t,Amount)]) -> Rand g Money
recVal est (reac,prod) = liftM2 (\r p -> p - r) (recSide est reac) (recSide est prod)

netValue :: (t -> Rand g Money) -> [([(t,Amount)],[(t,Amount)])] -> Rand g [Money]
netValue est = mapM (recVal est)

class (Tradable t) => Agent a t | a -> t where
	getID :: a -> Identifier
        getInventory :: a -> [(t,Amount)]
	replaceInventory  :: a -> [(t,Amount)] -> a
        getJob :: a -> t
        getMoney :: a -> Money
	replaceMoney :: a -> Money -> a
        updatePriceBeleifs :: a -> Either (Transaction t) (Bid t) -> Rand g a -- Either a transaction occured or a bid was rejected
	estimateValue :: a -> t -> Rand g Money
	amountToSell :: a -> t -> Maybe (Rand g (Bid t))
        amountToBuy :: a -> t -> Maybe (Rand g (Bid t))
	doProduction :: a -> Rand g a
	doProduction a = do { let possibleRecipes = filter (\(r,_) -> and $ map (\(t,am) -> maybe False (\v -> am >= v) (lookup t (getInventory a))) r) (recipes $ getJob a)
			; guessRecipe <- (\(l,rl) -> fmap (zip l) (sequence rl)) $ unzip possibleRecipes
			; valueRecipe <- netValue (estimateValue a) guessRecipe
			; let recAndVal = zip valueRecipe guessRecipe
			; let chosenRecipe = snd $ head $ sortBy (\(v1,_) (v2,_) -> compare v1 v2) recAndVal
			; let removedReactants = foldl' (\inv (t,am) -> adjust (\n -> n - am) t inv) (getInventory a) (fst chosenRecipe)
			; let addProducts      = foldl' (\inv (t,am) -> adjust (\n -> n + am) t inv) removedReactants (snd chosenRecipe)
			; return $ (\a' -> replaceMoney a' ((getMoney a) - 2)) $ replaceInventory a addProducts }
	doTurn :: a -> Rand g (a,[Bid t],[Bid t])
	doTurn a = do {
			postProd <- doProduction a ;
			sells    <- sequence $ mapMaybe (\(k,_) -> amountToSell a k) $ getInventory postProd ;
			buys     <- sequence $ mapMaybe (\(k,_) -> amountToBuy  a k) $ getInventory postProd ;
			return (a,sells,buys)
	       		}

getByID :: (Tradable t, Agent a t) => [a] -> Identifier -> Maybe a
getByID [] _ = Nothing
getByID (x:xs) i = if (getID x) == i then Just x else getByID xs i

resolveBids :: Tradable t => [Bid t] -> [Bid t] -> (Bid t -> Bid t -> (Rand g (Transaction t), Maybe (Bid t, Bool))) -> [Either ((Identifier, Identifier), Rand g (Transaction t)) (Identifier, Bid t)]
resolveBids [] l _ = map (\b -> Right (bidder b, b)) l
resolveBids l [] f = resolveBids [] l f
resolveBids (s:ss) bs f = if elem (thing' s) (map thing' bs)
			     then let buy = head $ filter (\b -> (thing' b) == (thing' s)) bs 
		 		      (rtrans, mbb) = f s buy
	      			  in (Left ((bidder' s, bidder' buy), rtrans)) : ((\(s',b') -> resolveBids s' b' f) $ (\s' b' -> (s',b' \\ [buy])) (maybe ss (\(bid,isSell) -> if isSell then bid:ss else ss) mbb) (maybe bs (\(bid,isSell) -> if isSell then bs else bid:bs) mbb))
			     else (Right (bidder' s, s)):(resolveBids ss bs f)
			where
				thing' = (\Bid{ thing = that } -> that) :: Bid t -> t
				bidder' = (\Bid{ bidder = bid} -> bid) :: Bid t -> Identifier
				     {-
updateAgents :: (Tradable t, Agent a t) => t -> [Either ((Identifier, Identifier), (Transaction t)) (Identifier, Bid t)] -> [a] -> Rand g [a]
updateAgents etbs as = mapM (\a -> foldM (\etb a' -> updatePriceBeleifs a' etb) a $ filter (either (\((i1,i2),_) -> (i1 == (getID a)) || (i2 == (getID a))) (\(i,_) -> i == (getID a))) etbs) as

turnMean :: t -> [Transaction t] -> Money
turnMean t l = (\l' -> (sum $ map (\(x,am) -> x * am) l') / (sum $ map (\(_,am) -> am))) $ map (\ti -> (unit_price ti, quantitiy ti)) $ filter (\ti -> (item ti) == t) l

class (Tradable t, Agent a t) => ClearingHouse c a t | c -> t, c -> a where
	getAgents :: c -> [a]
	getAgentByID :: c -> Identifier -> Maybe a
	getAgentByID c = getByID (getAgents c)
	haggle :: c -> Bid t -> Bid t -> (Rand g (Transaction t), Maybe (Bid t, Bool)) -- If bool is true, then is a SELL
	defaultPrice :: c -> t -> Money
	tradeHistory :: c -> [[Transaction t]]
	updateHouse :: c -> [a] -> [Transaction t] -> c
	lastMean :: c -> t -> Money
	lastMean c t = turnMean t $ head c
	observedMean :: c -> t -> Money
	replaceAgent :: c -> [(t,Amount)] -> Rand g a
	doRound :: c -> Rand g c
	doRound c = do { asbp <- mapM doTurn $ getAgents c
			; let (agents,sells,buys) = (\(as,sl,bl) -> (as, concat sl, concat bl)) $ unzip3 asbp
			; let sortSells = sortBy (\s1 s2 -> compare (cost s1) (cost s2)) sells
			; let sortBuys  = reverse $ sortBy (\b1 b2 -> compare (cost b1) (cost b2)) buys
			; let resolved  = resolveBids sortSells sortBuys (haggle c)
			; randResolved <- (sequence $ foldM (\bt bts -> (either (\(p,rt) -> liftRand (\g -> (Left (p,evalRand rt g),execRand rt g))) (\r -> return (Right r))) : bts) [] resolved) :: Rand g [Either ((Identifier, Identifier), Transaction t) (Identifier, Bid t)]
			; updatedAgents <- mapM (\a -> foldM (\etb a' -> updatePriceBeleifs a' etb) a $ filter (either (\((i1,i2),_) -> (i1 == (getID a)) || (i2 == (getID a))) (\(i,_) -> i == (getID a))) randResolved) agents
			; transactions <- sequence $ map snd $ lefts resolved
   			; let excessDemand = map (\t -> (t, (sum $ map number $ filter (\bid -> t == (thing bid)) buys) - (sum $ map number $ filter (\bid -> t == (thing bid)) sells))) $ nub $ map thing (buys ++ sells)
      			; let newAgents    = map (\a -> if (getMoney a) <= 0 then replaceAgent excessDemand else a)
			; return $ updateHouse c newAgents transactions }
-}
