module Economics.Agent
	(Money
	,Mass
	,Amount
	,Identifier
	,Tradable
	,Transaction(Transaction)
	,Agent
	,ClearingHouse
	) where
	
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExistentialQuantification #-}

import Control.Monad.Random
import System.Random
import Data.List
import Data.Maybe
import qualified Data.Map.Strict as Map

type Money  = Double
type Mass   = Double
type Amount = Int
type Identifier = Int

class (Eq a) => Tradable a where
        unit_mass :: a -> Mass
	recipes :: a -> [([a,Amount],Rand g [a,Amount])]

data Transaction t = (Tradable t) => Transaction {seller :: Identifier
                                                 ,buyer :: Identifier
                                                 ,item :: t
                                                 ,quantity :: Amount
                                                 ,unit_price :: Money
                                                 }

data Bid t = (Tradable t) => Bid {bidder :: Identifier
				 ,thing :: t
				 ,number :: Amount
				 ,cost :: Money
				 }

mapRadom :: (a -> b) -> Rand g [a] -> Rand g [b]
mapRandom f = foldr (\r z -> mapRand (\(i,g) -> (i : (evalRand z g), execRand z g)) r) (liftRand (\g -> ([],g)))

unboxRandom :: [Rand g a] -> Rand g [a]
unboxRandom []      = liftRand (\g -> ([],g))
unboxRandom (rx:xs) = liftRand (\g -> (evalRand rx g : $ evalRand (unboxRandom xs) (execRand rx g), execRand (unboxRandom xs) (execRand rx g)))

class (Tradable t) => Agent a t where
	getID :: a -> Identifier
        getInventory :: a -> Map t Amount
	replaceInventory  :: a -> Map t Amount -> a
        getJob :: a -> t
        getMoney :: a -> Money
	replaceMoney :: a -> Money -> a
        updatePriceBeleifs :: a -> Either (Transaction t) (Bid t) -> Rand g a -- Either a transaction occured or a bid was rejected
	estimateValue :: a -> t -> Money
	amountToSell :: a -> t -> Maybe (Rand g (Bid t))
        amountToBuy :: a -> t -> Maybe (Rand g (Bid t))
	doProduction :: a -> Rand g a
	doProduction a = do
				chosenRecipe     <- liftRand (\g -> ((\(fs,r2) -> (fs,evalRand r2 (snd $ next g))) $ head $ sortBy (\r1 r2 -> let f = (\r -> (sum $ map (estimatedValue a) $ evalRand g $ snd r) - (sum $ map (estimatedValue a) $ fst r)) in compare (f r1) (f r2)) possibleRecipes, snd $ next $ snd $ next g))
				removedReactants <- foldl' (\(t,am) -> adjust (\n -> n - am) t (getInventory a)) (fst chosenRecipe)
				addProducts      <- foldl' (\(t,am) -> adjust (\n -> n + am) t removedReactants) (snd chosenRecipe)
				liftRand (\g -> ((\a' -> replaceMoney a' ((getMoney a) - 2)) $ replaceInventory a addProducts, g))
		where
			possibleRecipes = filter (\(r,_) -> foldr (\(t,am) z -> z && (am >= $ maybe (am + 1) $ lookup t (getInventory a))) True r) (recipes $ getJob a)
	doTurn :: a -> Rand g (a,[Bid t],[Bid t])
	doTurn a = do
			postProd <- doProduction a
			sells    <- unboxRandom $ mapMaybe (\(k,_) -> amountToSell a k) $ toList (getInventory postProd)
			buys     <- unboxRandom $ mapMaybe (\(k,_) -> amountToBuy  a k) $ toList (getInventory postProd)
			liftRand (\g -> ((a,sells,buys),g))

getByID :: Agent a => [a] -> Identifier -> Maybe a
getByID [] _ = Nothing
getByID (x:xs) i = if (getID x) == i then x else getByID xs i

resolveBids :: (Tradable t) => [Bid t] -> [Bid t] -> (Bid t -> Bid t -> Rand g (Transaction t)) -> [Either ((Identifier, Identifier), Rand g (Transaction t)) (Identifier, Bid t)]
resolveBids [] l _ = map (\b -> Right (bidder b, b)) l
resolveBids l [] f = resolveBids [] l f
resolveBids (s:ss) bs f = if (thing s) `elem` $ map thing bs
			     then (Left ((bidder s, bidder $ head $ filter (\b->(thing b) == (thing s))), f s $ head $ filter (\b -> (thing b) == (thing s)) bs) : resolveBids ss $ bs \\ [head $ filter (\b -> (thing b) == (thing s))]
			     else (Right (bidder s, s)):(resolveBids ss bs)

rFilter :: Rand g [a] -> (a -> Bool) -> 

class (Tradable t, Agent a t) => ClearingHouse c a t | c -> t where
	getAgents :: c -> [a]
	getAgentByID :: c -> Identifier -> Maybe a
	getAgentByID c i = getByID (getAgents c)
	haggle :: Bid t -> Bid t -> Rand g (Transaction t)
	tradeHistory :: c -> [[Transaction a t]]
	updateHouse :: c -> [a] -> [Transaction a t] -> c
	turnMean :: t -> [Transaction a t] -> Money
	turnMean t l = (\l' -> (sum $ map (\(x,am) -> x * am) l') / (sum $ map (\(_,am) -> am))) $ map (\ti -> (unit_price ti, quantitiy ti)) $ filter (\ti -> (item ti) == t) l
	lastMean :: c -> t -> Money
	lastMean c t = turnMean t $ head c
	observedMean :: c -> t -> Money
	doRound :: c -> Rand g c
	doRound c = do
			asb <- unboxRandom $ map doTurn $ getAgents c
			agents <- map (\(a,_,_) -> a) asb
			sells  <- map (\(a,s,_) -> s) asb
			buys   <- map (\(a,_,b) -> b) asb
			sortSells <- sortBy (\s1 s2 -> compare (cost s1) (cost s2)) sells
			sortBuys  <- reverse $ sortBy (\b1 b2 -> compare (cost b1) (cost b2)) buys
			resolved  <- resolveBids sortSells sortBuys
			randResolved <- unboxRandom $ map (\etb -> liftRand (\g -> (either (\r -> evalRand r g) id etb, snd $ next g))) resolved
			agentResolvedMap <- unboxRandom 
			updatedAgents <- map (\a -> foldr (\t a' -> updatePriceBeleifs t a') a $ map () $ filter (either (\((i1,i2),) ) ()) resolved) agents
			--TODO figure out how to update each agent