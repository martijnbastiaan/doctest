{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE CPP #-}
module Run (
  doctest
, doctestWithOptions
, Summary(..)
#ifdef TEST
, expandDirs
#endif
) where

import           Prelude ()
import           Prelude.Compat

import           Control.Monad (when, unless)
import           System.Directory (doesFileExist, doesDirectoryExist, getDirectoryContents)
import           System.Environment (getEnvironment)
import           System.Exit (exitFailure, exitSuccess)
import           System.FilePath ((</>), takeExtension)
import           System.IO
import           System.IO.CodePage (withCP65001)

import qualified Control.Exception as E
import           Panic

import           PackageDBs
import           Parse
import           Options
import           Runner
import qualified Interpreter

-- | Run doctest with given list of arguments.
--
-- Example:
--
-- >>> doctest ["-iexample/src", "example/src/Example.hs"]
-- Examples: 2  Tried: 2  Errors: 0  Failures: 0
--
-- This can be used to create a Cabal test suite that runs doctest for your
-- project.
--
-- If a directory is given, it is traversed to find all .hs and .lhs files
-- inside of it, ignoring hidden entries.
doctest :: [String] -> IO ()
doctest args0 = case parseOptions args0 of
  Output s -> putStr s
  Result (warnings, config) -> do
    mapM_ (hPutStrLn stderr) warnings
    hFlush stderr

    i <- Interpreter.interpreterSupported
    unless i $ do
      hPutStrLn stderr "WARNING: GHC does not support --interactive, skipping tests"
      exitSuccess

    r <- doctestWithOptions config `E.catch` \e -> do
      case fromException e of
        Just (UsageError err) -> do
          hPutStrLn stderr ("doctest: " ++ err)
          hPutStrLn stderr "Try `doctest --help' for more information."
          exitFailure
        _ -> E.throwIO e
    when (not $ isSuccess r) exitFailure

-- | Expand a reference to a directory to all .hs and .lhs files within it.
expandDirs :: String -> IO [String]
expandDirs fp0 = do
    isDir <- doesDirectoryExist fp0
    if isDir
        then findHaskellFiles fp0
        else return [fp0]
  where
    findHaskellFiles dir = do
        contents <- getDirectoryContents dir
        concat <$> mapM go (filter (not . hidden) contents)
      where
        go name = do
            isDir <- doesDirectoryExist fp
            if isDir
                then findHaskellFiles fp
                else if isHaskellFile fp
                        then return [fp]
                        else return []
          where
            fp = dir </> name

    hidden ('.':_) = True
    hidden _ = False

    isHaskellFile fp = takeExtension fp `elem` [".hs", ".lhs"]

-- | Get the necessary arguments to add the @cabal_macros.h@ file and autogen
-- directory, if present.
getAddDistArgs :: IO ([String] -> [String])
getAddDistArgs = do
    env <- getEnvironment
    let dist =
            case lookup "HASKELL_DIST_DIR" env of
                Nothing -> "dist"
                Just x -> x
        autogen = dist ++ "/build/autogen/"
        cabalMacros = autogen ++ "cabal_macros.h"

    dirExists <- doesDirectoryExist autogen
    if dirExists
        then do
            fileExists <- doesFileExist cabalMacros
            return $ \rest ->
                  concat ["-i", dist, "/build/autogen/"]
                : "-optP-include"
                : (if fileExists
                    then (concat ["-optP", dist, "/build/autogen/cabal_macros.h"]:)
                    else id) rest
        else return id

isSuccess :: Summary -> Bool
isSuccess s = sErrors s == 0 && sFailures s == 0

doctestWithOptions :: Config -> IO Summary
doctestWithOptions Config{..} = do
  args <-
    if cfgMagicMode then do
      -- expand directories to absolute paths and read package environment from
      -- environment variables if magic mode is set.
      expandedArgs <- concat <$> mapM expandDirs cfgOptions
      packageDBArgs <- getPackageDBArgs
      addDistArgs <- getAddDistArgs
      return (addDistArgs $ packageDBArgs ++ expandedArgs)
    else
      return cfgOptions

  -- get examples from Haddock comments
  modules <- getDocTests args

  let run replE = runModules cfgFastMode cfgPreserveIt cfgVerbose replE modules

  if cfgIsolateModules then
    -- Run each module with its own interpreter
    run (Left args)
  else
    -- Run each module with same interpreter, potentially creating a dependency
    -- between them.
    Interpreter.withInterpreter args $ \repl -> withCP65001 $ run (Right repl)
