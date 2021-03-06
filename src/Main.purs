module Main where

import Prelude

import Control.Monad.Aff
import Control.Monad.Eff.Class
import Control.Monad.Eff.Console as Console
import Control.Monad.Eff.Unsafe (unsafePerformEff)
import Control.Monad.Eff.Exception
import Control.Monad.Error.Class (throwError)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Either (Either(..))
import Data.Map (insert)
import Data.Foreign (parseJSON, Foreign(), toForeign)
import Data.Foreign.Class (readProp)
import Data.Array (head, drop)
import Data.Foldable (elem)
import Data.List (List(Nil))
import Data.Version (Version(), version, showVersion, parseVersion)
import Data.String (stripPrefix)
import Text.Parsing.Parser (ParseError(..))
import Node.Encoding (Encoding(UTF8))
import Node.FS.Sync (readTextFile)
import Node.Path as Path
import Node.Process as Process

import Pulp.Args as Args
import Pulp.Args.Get
import Pulp.Args.Help
import Pulp.Args.Types as Type
import Pulp.Args.Parser (parse)
import Pulp.System.FFI
import Pulp.Outputter
import Pulp.Validate (validate)
import Pulp.Version (printVersion)
import Pulp.Project (getProject)

import Pulp.Init as Init
import Pulp.Bower as Bower
import Pulp.Build as Build
import Pulp.Run as Run
import Pulp.Test as Test
import Pulp.Browserify as Browserify
import Pulp.Docs as Docs
import Pulp.Psci as Psci
import Pulp.Server as Server
import Pulp.Login as Login
import Pulp.BumpVersion as BumpVersion
import Pulp.Publish as Publish
import Pulp.Watch as Watch
import Pulp.Shell as Shell

globals :: Array Args.Option
globals = [
  Args.option "bowerFile" ["--bower-file", "-b"] Type.file
    "Read this bower.json file instead of autodetecting it.",
  Args.option "watch" ["--watch", "-w"] Type.flag
    "Watch source directories and re-run command if something changes.",
  Args.option "monochrome" ["--monochrome"] Type.flag
    "Don't colourise log output.",
  Args.option "before" ["--before"] Type.string
    "Run a shell command before the operation begins. Useful with `--watch`, eg. `--watch --before clear`.",
  Args.option "then" ["--then"] Type.string
    "Run a shell command after the operation finishes successfully. Useful with `--watch`, eg. `--watch --then 'say Done'`",
  Args.option "else" ["--else"] Type.string
    "Run a shell command if an operation finishes. Useful with `--watch`, eg. `--watch --then 'say Done' --else 'say Failed'`",
  Args.option "version" ["--version", "-v"] Type.flag
    "Show current pulp version."
  ]

defaultDependencyPath :: String
defaultDependencyPath =
  unsafePerformEff (catchException (const (pure "bower_components")) readFromBowerRc)
  where
  readFromBowerRc = do
    json <- readTextFile UTF8 ".bowerrc"
    case parseJSON json >>= readProp "directory" of
      Right dir -> pure dir
      Left err  -> throwException (error (show err))

-- | Options for any command requiring paths
pathArgs :: Array Args.Option
pathArgs = [
  Args.optionDefault "includePaths" ["--include", "-I"] Type.directories
    ("Additional directories for PureScript source files, separated by `" <> Path.delimiter <> "`.")
    ([] :: Array String),
  Args.optionDefault "srcPath" ["--src-path"] Type.directory
    "Directory for PureScript source files." "src",
  Args.optionDefault "testPath" ["--test-path"] Type.directory
    "Directory for PureScript test files." "test",
  Args.optionDefault "dependencyPath" ["--dependency-path"] Type.directory
    "Directory for PureScript dependency files." defaultDependencyPath
  ]

-- | Options common to 'build', 'test', and 'browserify'
buildishArgs :: Array Args.Option
buildishArgs = [
  Args.optionDefault "buildPath" ["--build-path", "-o"] Type.string
    "Path for compiler output." "./output",
  Args.option "noPsa" ["--no-psa"] Type.flag
    "Do not attempt to use the psa frontend instead of psc"
  ] <> pathArgs

buildArgs :: Array Args.Option
buildArgs = [
  Args.optionDefault "main" ["--main", "-m"] Type.string
    "Application's entry point." "Main",
  Args.option "to" ["--to", "-t"] Type.string
    "Output file name (stdout if not specified).",
  Args.option "optimise" ["--optimise", "-O"] Type.flag
    "Perform dead code elimination.",
  Args.option "skipEntryPoint" ["--skip-entry-point"] Type.flag
    "Don't add code to automatically invoke Main."
  ] <> buildishArgs

-- TODO: This is possibly just a temporary separation from buildArgs; at the
--       moment, the browserify action doesn't support this option, but it's
--       definitely in the realm of possibility.
moduleArgs :: Array Args.Option
moduleArgs = [
  Args.option "modules" ["--modules"] Type.string
    "Additional modules to be included in the output bundle (comma-separated list)."
  ]

remainderToPsc :: Maybe String
remainderToPsc = Just "Passthrough options are sent to `psc`."

remainderToTest :: Maybe String
remainderToTest =
  Just ("Passthrough options are sent to the test program. " <>
    "This can be useful for only running one particular test, for instance.")

remainderToBundle :: Maybe String
remainderToBundle =
  Just "Passthrough options are sent to `psc-bundle`."

remainderToProgram :: Maybe String
remainderToProgram =
  Just "Passthrough options are sent to your program."

remainderToPscDocs :: Maybe String
remainderToPscDocs =
  Just "Passthrough options are sent to `psc-docs`."

remainderToPsci :: Maybe String
remainderToPsci =
  Just "Passthrough options are sent to `psci`."

commands :: Array Args.Command
commands = [
  Args.command "init" "Generate an example PureScript project." Nothing Init.action [
     Args.option "force" ["--force"] Type.flag
       "Overwrite any project found in the current directory."
     ],
  Args.command "dep" "Invoke Bower for package management." Nothing Bower.action [],
  Args.command "build" "Build the project." remainderToPsc Build.action $
    buildArgs <> moduleArgs,
  Args.command "test" "Run project tests." remainderToTest Test.action $ [
    Args.optionDefault "main" ["--main", "-m"] Type.string
      "Test entry point." "Test.Main",
    Args.optionDefault "runtime" ["--runtime", "-r"] Type.string
      "Run test script using this command instead of Node." "node"
    ] <> buildishArgs,
  Args.command "browserify"
    "Produce a deployable bundle using Browserify." remainderToBundle Browserify.action $ [
      Args.option "transform" ["--transform"] Type.string
        "Apply a Browserify transform.",
      Args.option "sourceMap" ["--source-map"] Type.string
        "Generate source maps.",
      Args.option "force" ["--force"] Type.flag
        "Force a non-incremental build by deleting the build cache.",
      Args.option "standalone" ["--standalone"] Type.string
        "Output a UMD bundle with the given external module name."
      ] <> buildArgs,
  Args.command "run" "Compile and run the project." remainderToProgram Run.action $ [
    Args.optionDefault "runtime" ["--runtime", "-r"] Type.string
      "Run the program using this command instead of Node." "node"
    ] <> buildArgs,
  Args.command "docs" "Generate project documentation." remainderToPscDocs Docs.action $ [
    Args.option "withTests" ["--with-tests", "-t"] Type.flag
      "Include tests.",
    Args.option "withDependencies" ["--with-dependencies", "-d"] Type.flag
      "Include external dependencies."
    ] <> pathArgs,
  Args.command "psci"
    "Launch a PureScript REPL configured for the project." remainderToPsci
    Psci.action pathArgs,
  Args.command "server" "Launch a Webpack development server." Nothing Server.action $ [
      Args.optionDefault "main" ["--main", "-m"] Type.string
        "Application's entry point." "Main",
      Args.option "config" ["--config", "-c"] Type.file
        "Override the default Webpack config.",
      Args.optionDefault "port" ["--port", "-p"] Type.int
        "Port number to listen on." 1337,
      Args.optionDefault "host" ["--host"] Type.string
        "IP address to bind the server to." "localhost",
      Args.option "noInfo" ["--no-info"] Type.flag
        "Display no info to the console, only warnings and errors.",
      Args.option "quiet" ["--quiet", "-q"] Type.flag
        "Display nothing to the console when rebuilding."
    ] <> buildishArgs,
  Args.command "login" "Obtain and store a token for uploading packages to Pursuit." Nothing Login.action [],
  Args.commandWithArgs "version" "Bump and tag a new version in preparation for release." Nothing BumpVersion.action []
    [Args.argument "bump" Type.versionBump "How to bump the version. Acceptable values: 'major', 'minor', 'patch', or any specific version. If omitted, Pulp will prompt you for a version." false],
  Args.command "publish" "Publish a previously tagged version to Bower and Pursuit." Nothing Publish.action [
      Args.optionDefault "pushTo" ["--push-to"] Type.string
        "The Git remote to push commits and tags to." "origin",
      Args.option "noPush" ["--no-push"] Type.flag
        "Skip pushing commits or tags to any remote."
    ]
  ]

failed :: forall a. Error -> EffN a
failed err = do
  Console.error $ "* ERROR: " <> message err
  -- logStack err
  Process.exit 1

foreign import logStack :: Error -> EffN Unit

succeeded :: Unit -> EffN Unit
succeeded = const (pure unit)

main :: EffN Unit
main = void $ runAff failed succeeded do
                requireNodeAtLeast (version 4 0 0 Nil Nil)
                argv <- drop 2 <$> liftEff Process.argv
                args <- parse globals commands argv
                case args of
                  Left (ParseError { message: err }) ->
                    handleParseError (head argv) err
                  Right args' -> do
                    runArgs args'
  where
  handleParseError (Just x) err
    -- TODO: this is kind of gross, especially that --version and --help are
    -- repeated
    | x `elem` ["--version", "-v"] = printVersion
    | x `elem` ["--help", "-h"]    = printHelp out globals commands

  handleParseError _ err = do
    out.err $ "Error: " <> err
    printHelp out globals commands

  out = makeOutputter false

runArgs :: Args.Args -> AffN Unit
runArgs args = do
  out <- getOutputter args
  if "--help" `elem` args.remainder
    then if args.command.name == "dep"
      then Bower.printHelp out
      else printCommandHelp out globals args.command
    else do
      _ <- validate out
      watch <- getFlag "watch" args.globalOpts
      if watch
        then
          Args.runAction Watch.action args
        else do
          args' <- addProject args
          runShellForOption "before" args'.globalOpts out
          result <- attempt $ Args.runAction args.command.action args'
          case result of
            Left e  -> do
              runShellForOption "else" args'.globalOpts out
              liftEff $ throwException e
            Right r ->
              runShellForOption "then" args'.globalOpts out
  where
  noProject = ["init", "login"]
  -- This is really quite gross, especially with _project. Not sure exactly
  -- how to go about improving this.
  addProject args =
    if args.command.name `elem` noProject
      then pure args
      else do
        proj <- getProject args.globalOpts
        let globalOpts' = insert "_project" (Just (toForeign proj)) args.globalOpts
        pure $ args { globalOpts = globalOpts' }
  runShellForOption option opts out = do
    triggerCommand <- getOption option opts
    case triggerCommand of
      Just cmd -> Shell.shell out cmd
      Nothing  -> pure unit

requireNodeAtLeast :: Version -> AffN Unit
requireNodeAtLeast minimum = do
  case parseVersion (stripV Process.version) of
    Left (ParseError { message }) ->
      throwError (error ("Failed to parse node.js version: " <> message))
    Right actual ->
      when (actual < minimum)
        (throwError (error
          ("Your node.js version is too old " <>
           "(required: " <> showVersion minimum <>
           ", actual: " <> showVersion actual <> ")")))

  where
  stripV str =
    fromMaybe str (stripPrefix "v" str)

argsParserDiagnostics :: Args.Args -> AffN Unit
argsParserDiagnostics opts = do
  let out = makeOutputter false
  out.log $ "Globals: " <> show ((map <<< map) showForeign opts.globalOpts)
  out.log $ "Command: " <> opts.command.name
  out.log $ "Locals: " <> show ((map <<< map) showForeign opts.commandOpts)
  out.log $ "Remainder: " <> show opts.remainder
  where
  showForeign :: Foreign -> String
  showForeign = unsafeInspect
