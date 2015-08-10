{-# LANGUAGE LambdaCase, RankNTypes, EmptyCase,
             StandaloneDeriving, FlexibleContexts,
             DeriveDataTypeable, DeriveFoldable,
             DeriveFunctor, DeriveTraversable,
             ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-} -- for Streaming show instance
module Streaming.Internal where

import Control.Monad
import Control.Monad.Trans
import Control.Applicative
import Data.Data ( Data, Typeable )
import Data.Foldable ( Foldable )
import Data.Traversable
import Control.Monad.Morph
import Data.Monoid
import Data.Functor.Identity
import GHC.Exts ( build )

-- some instances might better be explicit
data Of a b = !a :> b
    deriving (Data, Eq, Foldable, Functor, Ord,
              Read, Show, Traversable, Typeable)
infixr 4 :>

kurry :: (Of a b -> c) -> a -> b -> c
kurry f = \a b -> f (a :> b)
{-# INLINE kurry #-}

unkurry :: (a -> b -> c) -> Of a b -> c
unkurry f = \(a :> b) -> f a b
{-# INLINE unkurry #-}

-- explicit Stream/FreeT data type
data Stream f m r = Step (f (Stream f m r))
                  | Delay (m (Stream f m r))
                  | Return r
                  deriving (Typeable)


deriving instance (Show r, Show (m (Stream f m r))
                  , Show (f (Stream f m r))) => Show (Stream f m r)
deriving instance (Eq r, Eq (m (Stream f m r))
                  , Eq (f (Stream f m r))) => Eq (Stream f m r)

instance (Functor f, Monad m) => Functor (Stream f m) where
  fmap f = loop where
    loop = \case Step f  -> Step (fmap loop f)
                 Delay m       -> Delay (liftM loop m)
                 Return r       -> Return (f r)

instance (Functor f, Monad m) => Monad (Stream f m) where
  return = Return
  {-# INLINE return #-}
  (>>=) = flip seriesBind where
    seriesBind f = buildStream . foldBind (foldStream . f) . foldStream
    {-# INLINE seriesBind #-}
  {-# INLINE (>>=) #-}
    -- loop lst where
    -- loop = \case Step f -> Step (fmap loop f)
    --              Delay m      -> Delay (liftM loop m)
    --              Return r      -> f r

instance (Functor f, Monad m) => Applicative (Stream f m) where
  pure = Return; (<*>) = ap

instance Functor f => MonadTrans (Stream f) where
  lift = Delay . liftM Return

instance Functor f => MFunctor (Stream f) where
  hoist trans = loop where
    loop = \case Step f -> Step (fmap loop f)
                 Delay m      -> Delay (trans (liftM loop m))
                 Return r      -> Return r

instance (MonadIO m, Functor f) => MonadIO (Stream f m) where
  liftIO = Delay . liftM Return . liftIO

-- church encodings:
-- ----- unwrapped synonym:
type Folding_ f m r = forall r'
                   .  (f r' -> r')
                   -> (m r' -> r')
                   -> (r -> r')
                   -> r'
-- ------ wrapped:
newtype Folding f m r = Folding {getFolding :: Folding_ f m r  }

-- these should perhaps be expressed with
-- predefined combinators for Folding_
instance Functor (Folding f m) where
  fmap f phi = Folding (\construct wrap done ->
    getFolding phi construct
                wrap
                (done . f))

instance Monad (Folding f m) where
  return r = Folding (\construct wrap done -> done r)
  (>>=) = flip foldBind
  {-# INLINE (>>=) #-}

foldBind f phi = Folding (\construct wrap done ->
  getFolding phi construct
              wrap
              (\a -> getFolding (f a) construct
                                   wrap
                                   done))
{-# INLINE foldBind #-}

instance Applicative (Folding f m) where
  pure r = Folding (\construct wrap done -> done r)
  phi <*> psi = Folding (\construct wrap done ->
    getFolding phi construct
                wrap
                (\f -> getFolding psi construct
                                   wrap
                                   (\a -> done (f a))))

instance MonadTrans (Folding f) where
  lift ma = Folding (\constr wrap done -> wrap (liftM done ma))

instance Functor f => MFunctor (Folding f) where
  hoist trans phi = Folding (\construct wrap done ->
    getFolding phi construct (wrap . trans) done)

instance (MonadIO m, Functor f) => MonadIO (Folding f m) where
  liftIO io = Folding (\construct wrap done ->
             wrap (liftM done (liftIO io))
                )
  {-# INLINE liftIO #-}

-- -------------------------------------
-- optimization operations: wrapped case
-- -------------------------------------

--

-- `foldStream` is a flipped and wrapped variant of Atkey's
-- effectfulFolding :: (Functor f, Monad m) =>
--    (m x -> x) -> (r -> x) -> (f x -> x) -> Stream f m r -> x
-- modulo the 'Return' constructor, which implicitly restricts the
-- available class of Functors.
-- See http://bentnib.org/posts/2012-01-06-streams.html and
-- the (nightmarish) associated paper.

-- Our plan is thus where possible to replace the datatype Stream with
-- the associated effectfulFolding itself, wrapped as Folding

foldStream  :: (Functor f, Monad m) => Stream f m t -> Folding f m t
foldStream lst = Folding (\construct wrap done ->
  let loop = \case Delay mlst -> wrap (liftM loop mlst)
                   Step flst  -> construct (fmap loop flst)
                   Return r   -> done r
  in  loop lst)
{-# INLINE[0] foldStream  #-}

buildStream :: Folding f m r -> Stream f m r
buildStream (Folding phi) = phi Step Delay Return
{-# INLINE[0] buildStream #-}


-- The compiler has no difficulty with the rule for the wrapped case.
-- I have not investigated whether the remaining newtype
-- constructor is acting as an impediment. The stage [0] or [1]
-- seems irrelevant in either case.

{-# RULES
  "foldStream/buildStream" forall phi.
    foldStream (buildStream phi) = phi
    #-}

-- -------------------------------------
-- optimization operations: unwrapped case
-- -------------------------------------
destroy 
  :: (Functor f, Monad m) =>
     Stream f m r -> (f b -> b) -> (m b -> b) -> (r -> b) -> b
destroy = \lst construct wrap done ->
   let loop = \case Delay mlst -> wrap (liftM loop mlst)
                    Step flst  -> construct (fmap loop flst)
                    Return r   -> done r 
   in loop lst
{-# INLINE destroy #-}

construct
  :: (forall b . (f b -> b) -> (m b -> b) -> (r -> b) -> b) ->  Stream f m r
construct = \phi -> phi Step Delay Return
{-# INLINE construct #-}


foldStreamx
  :: (Functor f, Monad m) =>
     Stream f m t -> (f b -> b) -> (m b -> b) -> (t -> b) -> b
foldStreamx = \lst construct wrap done ->
   let loop = \case Delay mlst -> wrap (liftM loop mlst)
                    Step flst  -> construct (fmap loop flst)
                    Return r   -> done r
   in  loop lst
{-# INLINE[1] foldStreamx #-}


buildStreamx = \phi -> phi Step Delay Return
{-# INLINE[1] buildStreamx #-}

-- The compiler seems to have trouble seeing these rules as applicable,
-- unlike those for foldStream & buildStream. Opaque arity is
-- a plausible hypothesis when you know nothing yet.
-- When additional arguments are given to a rule,
-- the most saturated is the one that fires,
-- but it only fires where this one would.

{-# RULES

  "foldStreamx/buildStreamx" forall phi.
    foldStreamx (buildStreamx phi) = phi

    #-}


buildList_ :: Folding_ (Of a) Identity () -> [a]
buildList_ phi = phi (\(a :> as) -> a : as)
                     (\(Identity xs) -> xs)
                     (\() -> [])
{-# INLINE buildList_ #-}

buildListM_ :: Monad m => Folding_ (Of a) m () -> m [a]
buildListM_ phi = phi (\(a :> mas) -> liftM (a :) mas)
                      (>>= id)
                      (\() -> return [])
{-# INLINE buildListM_ #-}

foldList_ :: Monad m => [a] -> Folding_ (Of a) m ()
foldList_ xs = \construct wrap done ->
           foldr (\x r -> construct (x:>r)) (done ()) xs
{-# INLINE foldList_ #-}


buildList :: Folding (Of a) Identity () -> [a]
buildList = \(Folding phi) -> buildList_ phi
{-# INLINE[0] buildList #-}

foldList :: Monad m => [a] -> Folding (Of a) m ()
foldList = \xs -> Folding (foldList_ xs)
{-# INLINE[0] foldList #-}

{-# RULES
  "foldr/buildList" forall phi op seed .
    foldr op seed (buildList phi) =
       getFolding phi (unkurry op) runIdentity (\() -> seed)
    #-}
    
{-# RULES
  "foldr/buildList_" forall (phi :: Folding_ (Of a) Identity ()) 
                            (op :: a -> b -> b) 
                            (seed :: b) .
    foldr op seed (buildList_ phi) =
       phi (unkurry op) runIdentity (\() -> seed)
    #-}

{-# RULES
  "foldList/buildList" forall phi.
    foldList(buildList phi) = phi
    #-}               