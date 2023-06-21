module Main (main) where

import Control.Monad (forever, when)
import Data.Aeson (decode)
import Data.Aeson.KeyMap (toHashMapText)
import Data.ByteString.Lazy (fromStrict)
import Data.Cache (Cache, insert, newCache)
import Data.Cache qualified as Cache
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.IO.Handle (hGetLine)
import Lib (flattenObject)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (std_out), StdStream (CreatePipe), createProcess, proc, readProcess, readProcessWithExitCode)
import Prelude

type PlistCache = Cache FilePath (HashMap T.Text T.Text)

main :: IO ()
main = do
  putStrLn "Watching plist files..."
  plistCache <- newCache Nothing :: IO PlistCache
  let fswatchArgs = ["-r", "--include=.*\\.plist$", "--exclude=.*", "/"]
  (_, Just hout, _, _) <- createProcess (proc "fswatch" fswatchArgs) {std_out = CreatePipe}
  forever $ do
    path <- hGetLine hout
    printPlistFile plistCache path

printPlistFile :: PlistCache -> FilePath -> IO ()
printPlistFile cache path = do
  putStrLn $ "Plist file changed: " ++ path
  previousContents <- Cache.lookup cache path
  (exitCode, xmlData) <- callPlistBuddy "Print" path
  case exitCode of
    ExitSuccess -> do
      currentContents <- convertPlistToJSON xmlData
      case previousContents of
        Just oldContents -> do
          -- Find the updated keys
          let updatedKeys = HashMap.keys $ HashMap.intersection currentContents oldContents
          -- Generate and print the Set commands for the updated keys with changes
          mapM_ (printSetCommand oldContents currentContents path) updatedKeys
          -- Update the cache with the new contents
          insert cache path currentContents
        Nothing -> do
          -- Add the file to the cache without generating PlistBuddy commands
          insert cache path currentContents
      return ()
    _ -> do
      TIO.putStrLn $ "Error reading plist file: " <> T.pack path <> " - " <> xmlData
      return ()

printSetCommand :: HashMap T.Text T.Text -> HashMap T.Text T.Text -> FilePath -> T.Text -> IO ()
printSetCommand oldContents currentContents path key =
  let oldValue = oldContents HashMap.! key
      newValue = currentContents HashMap.! key
   in when (oldValue /= newValue) $ TIO.putStrLn $ generateSetCommand key newValue $ T.pack path

callPlistBuddy :: String -> FilePath -> IO (ExitCode, T.Text)
callPlistBuddy command path = do
  let plistBuddyArgs = ["-x", "-c", command, path]
  (exitCode, output, _) <- readProcessWithExitCode "/usr/libexec/PlistBuddy" plistBuddyArgs ""
  return (exitCode, T.pack output)

convertPlistToJSON :: T.Text -> IO (HashMap T.Text T.Text)
convertPlistToJSON xmlInput = do
  jsonString <- T.pack <$> readProcess "node" ["index.js", T.unpack xmlInput] ""
  case decode (fromStrict $ encodeUtf8 jsonString) of
    Just obj -> return $ T.pack . show <$> toHashMapText (flattenObject obj)
    Nothing -> return HashMap.empty

generateSetCommand :: T.Text -> T.Text -> T.Text -> T.Text
generateSetCommand key value path =
  "/usr/libexec/PlistBuddy -c \"Set " <> key <> " " <> value <> "\"" <> " " <> path
