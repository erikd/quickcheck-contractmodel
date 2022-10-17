module Test.QuickCheck.ContractModel.DL where

import Test.QuickCheck.ContractModel.Internal
import Test.QuickCheck.DynamicLogic.Monad qualified as DL

-- | An instance of a `DL` scenario generated by `forAllDL`. It is turned into a `Actions` before
--   being passed to the property argument of `forAllDL`, but in case of a failure the generated
--   `DLTest` is printed. This test can then be rerun using `withDLTest`.
data DLTest state =
    BadPrecondition [TestStep state] [FailedStep state] state
        -- ^ An explicit `action` failed its precondition (@[Action](#v:Action)@), or an assertion failed (`Assert`).
        --   There is a list of `FailedStep`s because there may be multiple branches
        --   (`Control.Applicative.<|>`) in the scenario that fail. Contains the contract state at
        --   the point of failure.
  | Looping         [TestStep state]
        -- ^ Test case generation from the `DL` scenario failed to terminate. See `stopping` for
        --   more information.
  | Stuck           [TestStep state] state
        -- ^ There are no possible next steps in the scenario. Corresponds to a call to
        --  `Control.Applicative.empty`. Contains the contract state at the point where the scenario
        --  got stuck.
  | DLScript        [TestStep state]
        -- ^ A successfully generated test case.

-- | This type captures the two different kinds of `BadPrecondition`s that can occur.
data FailedStep state = Action (Act state)
                        -- ^ A call to `action` that does not satisfy its `precondition`.
                      | Assert String
                        -- ^ A call to `DL.assert` or `assertModel` failed, or a `fail` in the `DL`
                        --   monad. Stores the string argument of the corresponding call.

deriving instance ContractModel s => Show (FailedStep s)
instance ContractModel s => Eq (FailedStep s) where
  Assert s == Assert s'                                   = s == s'
  Action (ActWaitUntil _ n) == Action (ActWaitUntil _ n') = n == n'
  Action a == Action a'                                   = actionOf a == actionOf a'
  _ == _                                                  = False

instance ContractModel s => Show (DLTest s) where
    show (BadPrecondition as bads s) =
        unlines $ ["BadPrecondition"] ++
                  bracket (map show as) ++
                  ["  " ++ show (nub bads)] ++
                  ["  " ++ showsPrec 11 s ""]
    show (Looping as) =
        unlines $ ["Looping"] ++ bracket (map show as)
    show (Stuck as s) =
        unlines $ ["Stuck"] ++ bracket (map show as) ++ ["  " ++ showsPrec 11 s ""]
    show (DLScript as) =
        unlines $ ["DLScript"] ++ bracket (map show as)

bracket :: [String] -> [String]
bracket []  = ["  []"]
bracket [s] = ["  [" ++ s ++ "]"]
bracket (first:rest) = ["  ["++first++", "] ++
                       map (("   "++).(++", ")) (init rest) ++
                       ["   " ++ last rest ++ "]"]

-- | One step of a test case. Either an `Action` (`Do`) or a value generated by a `DL.forAllQ`
--   (`Witness`). When a `DLTest` is turned into a `Actions` to be executed the witnesses are
--   stripped away.
data TestStep s = Do (Act s)
                | forall a. (Eq a, Show a, Typeable a) => Witness a

instance ContractModel s => Show (TestStep s) where
  show (Do act)    = "Do $ "++show act
  show (Witness a) = "Witness ("++show a++" :: "++show (typeOf a)++")"

toDLTest :: ContractModel state =>
              DLTest state -> DL.DynLogicTest (ModelState state)
toDLTest (BadPrecondition steps acts s) =
  DL.BadPrecondition (toDLTestSteps steps) (map conv acts) (dummyModelState s)
    where
        conv (Action (ActWaitUntil _ n)) = Some (WaitUntil n)
        conv (Action a)                  = Some (ContractAction (isBind a) (actionOf a))
        conv (Assert e)                  = Error e
toDLTest (Looping steps) =
  DL.Looping (toDLTestSteps steps)
toDLTest (Stuck steps s) =
  DL.Stuck (toDLTestSteps steps) (dummyModelState s)
toDLTest (DLScript steps) =
  DL.DLScript (toDLTestSteps steps)

toDLTestSteps :: ContractModel state =>
                   [TestStep state] -> [DL.TestStep (ModelState state)]
toDLTestSteps steps = map toDLTestStep steps

toDLTestStep :: ContractModel state =>
                  TestStep state -> DL.TestStep (ModelState state)
toDLTestStep (Do (ActWaitUntil v n)) = DL.Do $ v StateModel.:= WaitUntil n
toDLTestStep (Do act)                = DL.Do $ varOf act StateModel.:= ContractAction (isBind act) (actionOf act)
toDLTestStep (Witness a)             = DL.Witness a

fromDLTest :: forall s. DL.DynLogicTest (ModelState s) -> DLTest s
fromDLTest (DL.BadPrecondition steps acts s) =
  BadPrecondition (fromDLTestSteps steps) (concatMap conv acts) (_contractState s)
  where conv :: Any (StateModel.Action (ModelState s)) -> [FailedStep s]
        conv (Some (ContractAction _ act)) = [Action $ NoBind (Var 0) act]
        conv (Some (WaitUntil n))          = [Action $ ActWaitUntil (Var 0) n]
        conv (Some Unilateral{})           = []
        conv (Error e)                     = [Assert e]
fromDLTest (DL.Looping steps) =
  Looping (fromDLTestSteps steps)
fromDLTest (DL.Stuck steps s) =
  Stuck (fromDLTestSteps steps) (_contractState s)
fromDLTest (DL.DLScript steps) =
  DLScript (fromDLTestSteps steps)

fromDLTestSteps :: [DL.TestStep (ModelState state)] -> [TestStep state]
fromDLTestSteps steps = concatMap fromDLTestStep steps

fromDLTestStep :: DL.TestStep (ModelState state) -> [TestStep state]
fromDLTestStep (DL.Do (v := ContractAction b act)) = [Do $ if b then Bind v act else NoBind v act]
fromDLTestStep (DL.Do (v := WaitUntil n))          = [Do $ ActWaitUntil v n]
fromDLTestStep (DL.Do (_ := Unilateral{}))         = []
fromDLTestStep (DL.Witness a)                      = [Witness a]

-- | Run a specific `DLTest`. Typically this test comes from a failed run of `forAllDL`
--   applied to the given `DL` scenario and property. Useful to check if a particular problem has
--   been fixed after updating the code or the model.
withDLTest :: (ContractModel state, Testable prop)
           => DL state ()              -- ^ The `DL` scenario
           -> (Actions state -> prop)   -- ^ The property. Typically a call to `propRunActions_`
           -> DLTest state             -- ^ The specific test case to run
           -> Property
withDLTest dl prop test = DL.withDLTest dl (prop . fromStateModelActions) (toDLTest test)

-- $dynamicLogic
--
-- Test scenarios are described in the `DL` monad (based on dynamic logic) which lets you freely mix
-- random sequences of actions (`anyAction`, `anyActions_`, `anyActions`) with specific
-- actions (`action`). It also supports checking properties of the model state (`DL.assert`,
-- `assertModel`), and random generation (`DL.forAllQ`).
--
-- For instance, a unit test for a simple auction contract might look something like this:
--
-- @
--  unitTest :: `DL` AuctionState ()
--  unitTest = do
--      `action` $ Bid w1 100
--      `action` $ Bid w2 150
--      `action` $ Wait endSlot
--      `action` $ Collect
-- @
--
--  and could easily be extended with some randomly generated values
--
-- @
--  unitTest :: `DL` AuctionState ()
--  unitTest = do
--      bid <- `forAllQ` $ `chooseQ` (1, 100)
--      `action` $ Bid w1 bid
--      `action` $ Bid w2 (bid + 50)
--      `action` $ Wait endSlot
--      `action` $ Collect
-- @
--
-- More interesting scenarios can be constructed by mixing random and fixed sequences. The following
-- checks that you can always finish an auction after which point there are no funds locked by the
-- contract:
--
-- @
-- finishAuction :: `DL` AuctionState ()
-- finishAuction = do
--   `anyActions_`
--   `action` $ Wait endSlot
--   `action` $ Collect
--   `assertModel` "Funds are locked!" (`Ledger.Value.isZero` . `lockedValue`)
-- @
--
-- `DL` scenarios are turned into QuickCheck properties using `forAllDL`.

-- $dynamicLogic_errors
--
-- In addition to failing the check that the emulator run matches the model, there are a few other
-- ways that test scenarios can fail:
--
-- * an explicit `action` does not satisfy its `precondition`
-- * a failed `DL.assert` or `assertModel`, or a monad `fail`
-- * an `Control.Applicative.empty` set of `Control.Applicative.Alternative`s
-- * the scenario fails to terminate (see `stopping`)
--
-- All of these occur at test case generation time, and thus do not directly say anything about the
-- contract implementation. However, together with the check that the model agrees with the emulator
-- they indirectly imply properties of the implementation. An advantage of this is that `DL` test
-- scenarios can be checked without running the contract through the emulator, which is much much
-- faster. For instance,
--
-- @
-- prop_FinishModel = `forAllDL` finishAuction $ const True
-- @
--
-- would check that the model does not think there will be any locked funds after the auction is
-- finished. Once this property passes, one can run the slower property that also checks that the
-- emulator agrees.

-- | The monad for writing test scenarios. It supports non-deterministic choice through
--   `Control.Applicative.Alternative`, failure with `MonadFail`, and access to the model state
--   through `GetModelState`. It is lazy, so scenarios can be potentially infinite, although the
--   probability of termination needs to be high enough that concrete test cases are always finite.
--   See `stopping` for more information on termination.
type DL state = DL.DL (ModelState state)

-- | Generate a specific action. Fails if the action's `precondition` is not satisfied.
action :: ContractModel state => Action state -> DL state ()
action cmd = do
  s <- getModelState
  DL.action (contractAction s cmd)

-- | Generate a specific action. Fails if the action's `precondition` is not satisfied.
waitUntilDL :: ContractModel state => Slot -> DL state ()
waitUntilDL = DL.action . WaitUntil

-- | Generate a random action using `arbitraryAction`. The generated action is guaranteed to satisfy
--   its `precondition`. Fails with `Stuck` if no action satisfying the precondition can be found
--   after 100 attempts.
anyAction :: DL state ()
anyAction = DL.anyAction

-- | Generate a sequence of random actions using `arbitraryAction`. All actions satisfy their
--   `precondition`s. The argument is the expected number of actions in the sequence chosen from a
--   geometric distribution, unless in the `stopping` stage, in which case as few actions as
--   possible are generated.
anyActions :: Int -> DL state ()
anyActions = DL.anyActions

-- | Generate a sequence of random actions using `arbitraryAction`. All actions satisfy their
--   `precondition`s. Actions may be generated until the `stopping` stage is reached; the expected length is size/2.
anyActions_ :: DL state ()
anyActions_ = DL.anyActions_

-- | Test case generation from `DL` scenarios have a target length of the action sequence to be
--   generated that is based on the QuickCheck size parameter (see `sized`). However, given that
--   scenarios can contain explicit `action`s it might not be possible to stop the scenario once the
--   target length has been reached.
--
--   Instead, once the target number of actions have been reached, generation goes into the
--   /stopping/ phase. In this phase branches starting with `stopping` are preferred, if possible.
--   Conversely, before the stopping phase, branches starting with `stopping`
--   are avoided unless there are no other possible choices.
--
--   For example, here is the definition of `anyActions`:
--
-- @
-- `anyActions` n = `stopping` `Control.Applicative.<|>` pure ()
--                        `Control.Applicative.<|>` (`weight` (fromIntegral n) >> `anyAction` >> `anyActions` n)
-- @
--
--   The effect of this definition is that the second or third branch will be taken until the desired number
--   of actions have been generated, at which point the `stopping` branch will be taken and
--   generation stops (or continues with whatever comes after the `anyActions` call).
--
--   Now, it might not be possible, or too hard, to find a way to terminate a scenario. For
--   instance, this scenario has no finite test cases:
--
-- @
-- looping = `anyAction` >> looping
-- @
--
--   To prevent test case generation from looping, if a scenario has not terminated after generating
--   @2 * n + 20@ actions, where @n@ is when the stopping phase kicks in, generation fails with a
--   `Looping` error.
stopping :: DL state ()
stopping = DL.stopping

-- | By default, `Control.Applicative.Alternative` choice (`Control.Applicative.<|>`) picks among
--   the next actions with equal probability. So, for instance, this code chooses between the actions
--   @a@, @b@ and @c@, with a probability @1/3@ of choosing each:
--
-- @
-- unbiasedChoice a b c = `action` a `Control.Applicative.<|>` `action` b `Control.Applicative.<|>` `action` c
-- @
--
--   To change this you can use `weight`, which multiplies the
--   relative probability of picking a branch by the given number.
--
--   For instance, the following scenario picks the action @a@ with probability @2/3@ and the action
--   @b@ with probability @1/3@:
--
-- @
-- biasedChoice a b = `weight` 2 (`action` a) `Control.Applicative.<|>` `weight` (`action` b)
-- @
--
--   Calls to `weight` need to appear at the top-level after a choice, preceding any actions
--   (`action`/`anyAction`) or random generation (`forAllQ`), or they will have no effect.
weight :: Double -> DL state ()
weight = DL.weight

-- | Sometimes test case generation should depend on QuickCheck's size
--   parameter. This can be accessed using @getSize@. For example, @anyActions_@ is defined by
--
-- @
-- anyActions_ = do n <- getSize
--                  anyActions (n `div` 2 + 1)
-- @
--
-- so that we generate a random number of actions, but on average half the size (which is about the same as
-- the average random positive integer, or length of a list).

getSize :: DL state Int
getSize = DL.getSize

-- | The `monitor` function allows you to collect statistics of your testing using QuickCheck
--   functions like `Test.QuickCheck.label`, `Test.QuickCheck.collect`, `Test.QuickCheck.classify`,
--   and `Test.QuickCheck.tabulate`. See also the `monitoring` method of `ContractModel` which is
--   called for all actions in a test case (regardless of whether they are generated by an explicit
--   `action` or an `anyAction`).
monitor :: (Property -> Property) -> DL state ()
monitor = DL.monitorDL

-- | Fail unless the given predicate holds of the model state.
--
--   Equivalent to
--
-- @
-- assertModel msg p = do
--   s <- `getModelState`
--   `DL.assert` msg (p s)
-- @
assertModel :: String -> (ModelState state -> Bool) -> DL state ()
assertModel = DL.assertModel

-- | Turn a `DL` scenario into a QuickCheck property. Generates a random `Actions` matching the
--   scenario and feeds it to the given property. The property can be a full property running the
--   emulator and checking the results, defined using `propRunActions_`, `propRunActions`, or
--   `propRunActionsWithOptions`. Assuming a model for an auction contract and `DL` scenario that
--   checks that you can always complete the auction, you can write:
--
-- @
-- finishAuction :: `DL` AuctionState ()
-- prop_Auction  = `propRunActions_` handles
--   where handles = ...
-- prop_Finish = `forAllDL` finishAuction prop_Auction
-- @
--
--   However, there is also value in a property that does not run the emulator at all:
--
-- @
-- prop_FinishModel = `forAllDL` finishAuction $ const True
-- @
--
--   This will check all the assertions and other failure conditions of the `DL` scenario very
--   quickly. Once this property passes a large number of tests, you can run the full property
--   checking that the model agrees with reality.
forAllDL :: (ContractModel state, Testable p) => DL state () -> (Actions state -> p) -> Property
forAllDL dl prop = DL.forAllMappedDL toDLTest fromDLTest fromStateModelActions dl prop

forAllDL_ :: (ContractModel state, Testable p) => DL state () -> (Actions state -> p) -> Property
forAllDL_ dl prop = DL.forAllMappedDL_ toDLTest fromDLTest fromStateModelActions dl prop

forAllUniqueDL :: (ContractModel state, Testable p) => Int -> ModelState state -> DL state () -> (Actions state -> p) -> Property
forAllUniqueDL nextVar state dl prop = DL.forAllUniqueDL nextVar state dl (prop . fromStateModelActions)

instance ContractModel s => DL.DynLogicModel (ModelState s) where
    restricted (ContractAction _ act) = restricted act
    restricted WaitUntil{}            = False
    restricted Unilateral{}           = True

instance GetModelState (DL state) where
    type StateType (DL state) = state
    getModelState = DL.getModelStateDL


