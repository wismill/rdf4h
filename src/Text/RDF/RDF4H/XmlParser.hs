{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE DoAndIfThenElse     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE TupleSections       #-}

-- |An parser for the RDF/XML format
-- <http://www.w3.org/TR/REC-rdf-syntax/>.

module Text.RDF.RDF4H.XmlParser
  ( XmlParser(..)
  , parseDebug -- [FIXME]
  , xmlEg
  , example11
  , example12
  ) where

import Text.RDF.RDF4H.ParserUtils hiding (Parser)
import Text.RDF.RDF4H.XmlParser.Utils
import Data.RDF.IRI
import Data.RDF.Types hiding (empty, resolveQName)
import qualified Data.RDF.Types as RDF
import Data.RDF.Graph.TList

import Debug.Trace
import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Monad.State.Strict
import Data.Semigroup ((<>))
import           Data.Set (Set)
import qualified Data.Set as S
--import           Data.Map (Map)
import qualified Data.Map as Map
--import Data.Maybe
import Data.Either
import Data.Bifunctor
--import Data.Foldable
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)
--import Data.Text.Encoding
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Encoding as T
import Xmlbf hiding (Node, Parser, State)
import qualified Xmlbf.Xeno as Xeno

data XmlParser = XmlParser (Maybe BaseUrl) (Maybe Text)

instance RdfParser XmlParser where
  parseString (XmlParser bUrl dUrl) = parseXmlRDF bUrl dUrl
  parseFile   (XmlParser bUrl dUrl) = parseFile'  bUrl dUrl
  parseURL    (XmlParser bUrl dUrl) = parseURL'   bUrl dUrl

parseFile' :: (Rdf a)
  => Maybe BaseUrl
  -> Maybe Text
  -> String
  -> IO (Either ParseFailure (RDF a))
parseFile' bUrl dUrl fpath = parseXmlRDF bUrl dUrl <$> TIO.readFile fpath

parseURL' :: (Rdf a)
  => Maybe BaseUrl -- ^ The optional base URI of the document.
  -> Maybe Text -- ^ The document URI (i.e., the URI of the document itself); if Nothing, use location URI.
  -> String -- ^ The location URI from which to retrieve the XML document.
  -> IO (Either ParseFailure (RDF a)) -- ^ The parse result, which is either a @ParseFailure@ or the RDF
                                      --   corresponding to the XML document.
parseURL' bUrl docUrl = parseFromURL (parseXmlRDF bUrl docUrl)

type Parser = ParserT (State ParseState)

-- |Local state for the parser (dependant on the parent xml elements)
data ParseState = ParseState
  { stateBaseUri :: Maybe BaseUrl
  , stateIdSet :: Set Text -- ^ set of rdf:ID found in the scope of the current base URI.
  , statePrefixMapping :: PrefixMappings
  , stateLang :: Maybe Text
  , stateNodeAttrs :: HashMap Text Text -- ^ Current node RDF attributes
  , stateSubject :: Maybe Subject
  , stateListIndex :: Int
  , stateGenId :: Int
  } deriving(Show)

data ParserException = ParserException String
                     deriving (Show)
instance Exception ParserException

-- |Parse a xml Text to an RDF representation
parseXmlRDF :: (Rdf a)
  => Maybe BaseUrl     -- ^ The base URL for the RDF if required
  -> Maybe Text        -- ^ DocUrl: The request URL for the RDF if available
  -> Text              -- ^ The contents to parse
  -> Either ParseFailure (RDF a) -- ^ The RDF representation of the triples or ParseFailure
parseXmlRDF bUrl dUrl = parseRdf . parseXml
  where
    bUrl' = BaseUrl <$> dUrl <|> bUrl
    parseXml = Xeno.fromRawXml . T.encodeUtf8
    parseRdf = first ParseFailure . join . second parseRdf'
    parseRdf' ns = evalState (runParserT rdfParser ns) initState
    initState = ParseState bUrl' mempty mempty empty mempty empty 0 0

parseDebug :: String -> IO (RDF TList)
parseDebug f = fromRight RDF.empty <$> parseFile (XmlParser (Just . BaseUrl $ "http://plouf/") (Just "plouf")) f

rdfParser :: Rdf a => Parser (RDF a)
rdfParser = do
  bUri <- currentBaseUri
  triples <- (pRdf <* pWs) <||> pNodeElementList
  pEndOfInput
  pm <- currentPrefixMappings
  pure $ mkRdf triples bUri pm

pRdf :: Parser Triples
pRdf = pAnyElement $ do
  attrs <- pRDFAttrs
  uri <- pName >>= pQName
  guard (uri == rdfTag)
  when (not $ HM.null attrs) $ pFail "rdf:RDF: The set of attributes should be empty."
  pNodeElementList

pQName :: Text -> Parser Text
pQName qn = do
  pm <- currentPrefixMappings
  let qn' = resolveQName pm qn >>= validateIRI
  either pFail pure qn'

-- |Process the attributes of a node
pRDFAttrs :: Parser (HashMap Text Text)
pRDFAttrs = do
  -- Language (xml:lang)
  liftA2 (<|>) pLang currentLang >>= setLang
  -- Base URI
  -- [TODO] resolve base uri in context
  liftA2 (<|>) pBase currentBaseUri >>= setBaseUri
  bUri <- currentBaseUri
  -- Process the rest of the attributes
  attrs <- pAttrs
  -- Get the namespace definitions (xmlns:)
  pm <- updatePrefixMappings (PrefixMappings $ HM.foldlWithKey' mkNameSpaces mempty attrs)
  -- Filter and resolve RDF attributes
  let as = HM.foldlWithKey' (mkRdfAttribute pm bUri) mempty attrs
  setNodeAttrs as
  pure as
  where
    mkNameSpaces ns qn iri =
      -- [TODO] resolve IRI
      -- [TODO] check malformed identifiers & IRI
      let qn' = parseQName qn
          ns' = f <$> qn' <*> validateIRI iri
          f (Nothing     , "xmlns") iri' = Map.insert mempty iri' ns
          f (Just "xmlns", prefix ) iri' = Map.insert prefix iri' ns
          f _                       _    = ns
      in either (const ns) id ns'
    mkRdfAttribute pm bUri as qn v =
      let as' = parseQName qn >>= f
          f (Nothing, "xmlns")   = Right as
          f (Just "xmlns", _)    = Right as
          f qn'@(Just _, _)      = (\a -> HM.insert a v as) <$> resolveQName' pm qn'
          f (Nothing, uri)       = case bUri of
            Nothing -> Right as -- [FIXME] manage missing base URI
            Just (BaseUrl bUri') -> (\a -> HM.insert a v as) <$> resolveIRI bUri' uri
      in either (const as) id as'

pRDFAttr :: Text -> Parser Text
pRDFAttr a = do
  as <- currentNodeAttrs
  maybe
    (pFail $ mconcat ["Attribute \"", T.unpack a, "\" not found."])
    pure
    (HM.lookup a as)

pMatchAndRemoveAttr :: Text -> Parser Text
pMatchAndRemoveAttr a = pRDFAttr a <* removeNodeAttr a

pNodeElementList :: Parser Triples
pNodeElementList = pWs *> (mconcat <$> some (keepState pNodeElement <* pWs))

-- |White spaces parser
pWs :: Parser ()
pWs = maybe True (T.all ws . TL.toStrict) <$> optional pText >>= guard
  where
    -- See: https://www.w3.org/TR/2000/REC-xml-20001006#NT-S
    ws c = c == '\x20' || c == '\x09' || c == '\x0d' || c == '\x0a'

-- https://www.w3.org/TR/rdf-syntax-grammar/#nodeElement
pNodeElement :: Parser Triples
pNodeElement = pAnyElement $ do
  -- Process attributes
  void pRDFAttrs
  -- Process subject
  (s, mt) <- pSubject
  ts1 <- pPropertyAttrs s
  -- Process propertyEltList
  ts2 <- keepState pPropertyEltList
  setSubject (Just s)
  let ts = ts1 <> ts2
  pure $ maybe ts (:ts) mt

--pSubject :: Parser (Node, Triples)
pSubject :: Parser (Node, Maybe Triple)
pSubject = do
  mi <- optional pIdAttr
  traverse checkIdIsUnique mi
  -- Create the subject
  s <- pUnodeId <|> pBnode <|> pUnode <|> pBnodeGen
  -- traceM (show s)
  -- Resolve URI
  uri <- pName >>= pQName
  --currentBaseUri >>= traceM . show
  -- Check that the URI is allowed
  when (not (checkNodeUri uri)) (pFail $ "URI not allowed: " <> T.unpack uri)
  -- Optional rdf:type triple
  mtype <- optional (pType1 s uri)
  pure (s, mtype)
  where
    checkNodeUri uri = isNotCoreSyntaxTerm uri && uri /= rdfLi && isNotOldTerm uri
    pUnodeId = (pIdAttr >>= mkUNodeID) <* removeNodeAttr rdfID
    pBnode = do
      bn <- pNodeIdAttr <* removeNodeAttr rdfNodeID
      let s = BNode bn
      setSubject (Just s)
      pure s
    pUnode = do
      s <- unode <$> pAboutAttr <* removeNodeAttr rdfAbout
      setSubject (Just s)
      pure s
    -- Default subject: a new blank node
    pBnodeGen = do
      s <- newBNode
      setSubject (Just s)
      pure s
    pType1 n uri =
      if uri /= rdfDescription
        then pure $ Triple n rdfTypeNode (unode uri)
        else empty

pPropertyAttrs :: Node -> Parser Triples
pPropertyAttrs s = do
  attrs <- currentNodeAttrs
  HM.elems <$> HM.traverseWithKey f attrs
  where
    -- https://www.w3.org/TR/rdf-syntax-grammar/#propertyAttributeURIs
    isPropertyAttrURI uri =  isNotCoreSyntaxTerm uri
                          && uri /= rdfDescription
                          && uri /= rdfLi
                          && isNotOldTerm uri
    f attr value
      | not (isPropertyAttrURI attr) = pFail $ "URI not allowed for attribute: " <> T.unpack attr
      | attr == rdfType = pure $ Triple s rdfTypeNode (unode value)
      | otherwise = do
          lang <- currentLang
          pure $ let mkLiteral = maybe plainL (flip plainLL) lang
                 in Triple s (unode attr) (lnode (mkLiteral value))

pLang :: Parser (Maybe Text)
pLang = optional (pAttr "xml:lang")

pBase :: Parser (Maybe BaseUrl)
pBase = optional (BaseUrl <$> pAttr "xml:base")

pPropertyEltList :: Parser Triples
pPropertyEltList =  pWs
                 *> resetListIndex
                 *> fmap mconcat (many (pPropertyElt <* pWs))

pPropertyElt :: Parser Triples
pPropertyElt = pAnyElement $ do
  -- Process attributes
  void pRDFAttrs
  --attrs1 <- currentNodeAttrs
  --traceM ("pPropertyElt1 " <> show attrs1)
  p <- unode <$> (pName >>= pQName >>= listExpansion)
  -- [TODO] check URI
  pParseTypeLiteralPropertyElt p
    <||> pParseTypeResourcePropertyElt p
    <||> pParseTypeCollectionPropertyElt p
    <||> pParseTypeOtherPropertyElt p
    <||> pResourcePropertyElt p
    <||> pLiteralPropertyElt p
    <||> pEmptyPropertyElt p
  where
    listExpansion u
      | u == rdfLi = nextListIndex
      | otherwise  = pure u

pResourcePropertyElt :: Node -> Parser Triples
pResourcePropertyElt p = do
  pWs
  (ts1, o) <- keepState $ liftA2 (,) pNodeElement currentSubject
  pWs
  mi <- optional pIdAttr <* removeNodeAttr rdfID
  traverse checkIdIsUnique mi
  s <- currentSubject
  let mt = flip Triple p <$> s <*> o
  ts2 <- maybe (pure mempty) (uncurry reifyTriple) (liftA2 (,) mi mt)
  pure $ maybe (ts1 <> ts2) (:(ts1 <> ts2)) mt

pLiteralPropertyElt :: Node -> Parser Triples
pLiteralPropertyElt p = do
  mi <- optional pIdAttr <* removeNodeAttr rdfID
  traverse checkIdIsUnique mi
  dt <- optional pDatatypeAttr
  l <- pText
  s <- currentSubject
  lang <- currentLang
  let l' = TL.toStrict l
      o = lnode $ maybe (plainL l') id $ (typedL l' <$> dt) <|> (plainLL l' <$> lang)
      mt = (\s' -> Triple s' p o) <$> s
  ts <- maybe (pure mempty) (uncurry reifyTriple) (liftA2 (,) mi mt)
  pure $ maybe ts (:ts) mt

pParseTypeLiteralPropertyElt :: Node -> Parser Triples
pParseTypeLiteralPropertyElt p = do
  pt <- pRDFAttr rdfParseType
  guard (pt == "Literal")
  mi <- optional pIdAttr <* removeNodeAttr rdfID
  traverse checkIdIsUnique mi
  l <- pText -- [FIXME] XML literal
  s <- currentSubject
  let l' = TL.toStrict l
      o = lnode (typedL l' rdfXmlLiteral)
      mt = (\s' -> Triple s' p o) <$> s
  ts <- maybe (pure mempty) (uncurry reifyTriple) (liftA2 (,) mi mt)
  pure $ maybe ts (:ts) mt

pParseTypeResourcePropertyElt :: Node -> Parser Triples
pParseTypeResourcePropertyElt p = do
  pt <- pRDFAttr rdfParseType
  guard (pt == "Resource")
  mi <- optional pIdAttr <* removeNodeAttr rdfID
  traverse checkIdIsUnique mi
  s <- currentSubject
  o <- newBNode
  let mt = (\s' -> Triple s' p o) <$> s
  ts1 <- maybe (pure mempty) (uncurry reifyTriple) (liftA2 (,) mi mt)
  setSubject (Just o)
  ts2 <- keepListIndex pPropertyEltList
  setSubject s
  pure $ maybe (ts1 <> ts2) ((<> ts2) . (:ts1)) mt

pParseTypeCollectionPropertyElt :: Node -> Parser Triples
pParseTypeCollectionPropertyElt p = do
  pt <- pRDFAttr rdfParseType
  guard (pt == "Collection")
  mi <- optional pIdAttr <* removeNodeAttr rdfID
  traverse checkIdIsUnique mi
  s <- currentSubject
  case s of
    Nothing -> pure mempty
    Just s' -> do
      r <- optional pNodeElement
      case r of
        Nothing ->
          let t = Triple s' p rdfNilNode
          in ([t] <>) <$> maybe (pure mempty) (`reifyTriple` t) mi
        Just ts1 -> do
          s'' <- currentSubject
          n <- newBNode
          let t = Triple s' p n
              ts2 = maybe mempty (\s''' -> [t, Triple n rdfFirstNode s''']) s''
          ts3 <- go n
          ts4 <- maybe (pure mempty) (`reifyTriple` t) mi
          pure $ mconcat [ts1, ts2, ts3, ts4]
  where
    go s = do
      r <- optional pNodeElement
      case r of
        Nothing -> pure $ [Triple s rdfRestNode rdfNilNode]
        Just ts1 -> do
          s' <- currentSubject
          n <- newBNode
          let ts2 = maybe mempty (\s'' -> [Triple s rdfRestNode n, Triple n rdfFirstNode s'']) s'
          ts3 <- go n
          pure $ mconcat [ts1, ts2, ts3]

pParseTypeOtherPropertyElt :: Node -> Parser Triples
pParseTypeOtherPropertyElt _p = do
  pt <- pRDFAttr rdfParseType
  guard (pt /= "Resource" && pt /= "Literal" && pt /= "Collection")
  mi <- optional pIdAttr <* removeNodeAttr rdfID
  traverse checkIdIsUnique mi
  pFail "TODO" -- [TODO]

pEmptyPropertyElt :: Node -> Parser Triples
pEmptyPropertyElt p = do
  s <- currentSubject
  case s of
    Nothing -> pure mempty
    Just s' -> do
      mi <- optional pIdAttr <* removeNodeAttr rdfID
      traverse checkIdIsUnique mi
      o <- pResourceAttr' <|> pNodeIdAttr' <|> newBNode
      let t = Triple s' p o
      ts1 <- maybe (pure mempty) (`reifyTriple` t) mi
      ts2 <- pPropertyAttrs o
      pure (t:ts1 <> ts2)
  where
    pResourceAttr' = unode <$> pResourceAttr <* removeNodeAttr rdfResource
    pNodeIdAttr' = BNode <$> pNodeIdAttr <* removeNodeAttr rdfNodeID

pIdAttr :: Parser Text
pIdAttr = do
  i <- pRDFAttr rdfID
  either pFail pure (validateID i)

checkIdIsUnique :: Text -> Parser ()
checkIdIsUnique i = do
  notUnique <- S.member i <$> currentIdSet
  when notUnique (pFail $ "rdf:ID already used in this context: " <> T.unpack i)
  updateIdSet i

pNodeIdAttr :: Parser Text
pNodeIdAttr = do
  i <- pRDFAttr rdfNodeID
  either pFail pure (validateID i)

pAboutAttr :: Parser Text
pAboutAttr = pRDFAttr rdfAbout >>= checkIRI "rdf:about"

pResourceAttr :: Parser Text
pResourceAttr = pRDFAttr rdfResource >>= checkIRI "rdf:resource"

pDatatypeAttr :: Parser Text
pDatatypeAttr = pRDFAttr rdfDatatype >>= checkIRI "rdf:datatype"

-- [TODO]
pPropertyAttr :: Parser Triples
pPropertyAttr = do
  -- [FIXME] filter
  -- attrs <- HM.filterWithKey (\iri _ -> iri /= "rdf:type") <$> pAttrs
  attrs <- currentNodeAttrs
  s <- currentSubject
  lang <- currentLang
  let mkLiteral = lnode . maybe plainL (flip plainLL) lang
  pure $ maybe
    mempty
    (\s' -> HM.elems $ HM.mapWithKey (mkTriple s' mkLiteral) attrs)
    s
  where
    mkTriple s mkLiteral iri value = Triple s (unode iri) (mkLiteral value)

pNoMoreChildren :: Parser ()
pNoMoreChildren = pChildren >>= \case
  [] -> pure ()
  ns -> pFail $ "Unexpected remaining children: " <> show ns

-- | Try the first parser, if it fails restore the state and try the second parser.
(<||>) :: Parser a -> Parser a -> Parser a
(<||>) p1 p2 = do
  st <- get
  p1 <|> (put st *> p2)

checkIRI :: String -> Text -> Parser Text
checkIRI msg iri = do
  bUri <- maybe mempty unBaseUrl <$> currentBaseUri
  case uriValidate iri of
    Nothing   -> pFail $ mconcat ["Malformed IRI for \"", msg, "\": ", T.unpack iri]
    Just iri' -> either pFail pure (resolveIRI bUri iri')

-- https://www.w3.org/TR/rdf-syntax-grammar/#coreSyntaxTerms
isNotCoreSyntaxTerm :: Text -> Bool
isNotCoreSyntaxTerm uri
  =  uri /= rdfTag && uri /= rdfID && uri /= rdfAbout
  && uri /= rdfParseType && uri /= rdfResource
  && uri /= rdfNodeID && uri /= rdfDatatype

-- https://www.w3.org/TR/rdf-syntax-grammar/#oldTerms
isNotOldTerm :: Text -> Bool
isNotOldTerm uri =  uri /= rdfAboutEach
                 && uri /= rdfAboutEachPrefix
                 && uri /= rdfBagID

reifyTriple :: Text -> Triple -> Parser Triples
reifyTriple i (Triple s p' o) = do
  n <- mkUNodeID i
  pure [ Triple n rdfTypeNode rdfStatementNode
       , Triple n rdfSubjectNode s
       , Triple n rdfPredicateNode p'
       , Triple n rdfObjectNode o ]

newBNode :: Parser Node
newBNode = do
  modify $ \st -> st { stateGenId = stateGenId st + 1 }
  st <- get
  pure $ BNodeGen (stateGenId st)

-- Parser's state utils
currentGenID :: Parser Int
currentGenID = stateGenId <$> get

-- |Process a parser, restoring the state except for stateGenId and stateIdSet
keepState :: Parser a -> Parser a
keepState p = do
  st <- get
  let bUri = stateBaseUri st
      is = stateIdSet st
  p <* do
    st' <- get
    let i = stateGenId st'
        bUri' = stateBaseUri st'
        is' = stateIdSet st'
    -- Update the set of ID if necessary
    if bUri /= bUri'
      then put (st { stateGenId = i })
      else put (st { stateGenId = i, stateIdSet = is <> is' })

currentIdSet :: Parser (Set Text)
currentIdSet = stateIdSet <$> get

updateIdSet :: Text -> Parser ()
updateIdSet i = do
  is <- currentIdSet
  modify (\st -> st { stateIdSet = S.insert i is })

currentNodeAttrs :: Parser (HashMap Text Text)
currentNodeAttrs = stateNodeAttrs <$> get

setNodeAttrs :: HashMap Text Text -> Parser ()
setNodeAttrs as = modify (\st -> st { stateNodeAttrs = as })

removeNodeAttr :: Text -> Parser ()
removeNodeAttr a = HM.delete a <$> currentNodeAttrs >>= setNodeAttrs

currentPrefixMappings :: Parser PrefixMappings
currentPrefixMappings = statePrefixMapping <$> get

updatePrefixMappings :: PrefixMappings -> Parser PrefixMappings
updatePrefixMappings pm = do
  pm' <- (<> pm) <$> currentPrefixMappings
  modify (\st -> st { statePrefixMapping = pm' })
  pure pm'

currentListIndex :: Parser Int
currentListIndex = stateListIndex <$> get

setListIndex :: Int -> Parser ()
setListIndex i = modify (\st -> st { stateListIndex = i })

keepListIndex :: Parser a -> Parser a
keepListIndex p = do
  i <- currentListIndex
  p <* setListIndex i

-- See: https://www.w3.org/TR/rdf-syntax-grammar/#section-List-Expand
nextListIndex :: Parser Text
nextListIndex = do
  modify $ \st -> st { stateListIndex = stateListIndex st + 1 }
  (rdfListIndex <>) . T.pack . show . stateListIndex <$> get

resetListIndex :: Parser ()
resetListIndex = modify $ \st -> st { stateListIndex = 0 }

currentBaseUri :: Parser (Maybe BaseUrl)
currentBaseUri = stateBaseUri <$> get

setBaseUri :: (Maybe BaseUrl) -> Parser ()
setBaseUri u = modify (\st -> st { stateBaseUri = u })

mkUNodeID :: Text -> Parser Node
mkUNodeID t = currentBaseUri >>= pure . unode . \case
  Nothing          -> t
  Just (BaseUrl u) -> mconcat [u, "#", t]

currentSubject :: Parser (Maybe Subject)
currentSubject = stateSubject <$> get

setSubject :: (Maybe Subject) -> Parser ()
setSubject s = modify (\st -> st { stateSubject = s })

currentLang :: Parser (Maybe Text)
currentLang = stateLang <$> get

setLang :: (Maybe Text) -> Parser ()
setLang lang = modify (\st -> st { stateLang = lang })

example11 :: Text
example11 = T.pack $ unlines
  [ "<?xml version=\"1.0\"?>"
  , "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\""
  , "        xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
  , "         xmlns:ex=\"http://example.org/stuff/1.0/\">"
  , "  <rdf:Description rdf:about=\"http://www.w3.org/TR/rdf-syntax-grammar\""
  , "   dc:title=\"RDF/XML Syntax Specification (Revised)\">"
  , "  <ex:editor rdf:nodeID=\"abc\"/>"
  , "  </rdf:Description>"
  , "  <rdf:Description rdf:nodeID=\"abc\""
  , "                  ex:fullName=\"Dave Beckett\">"
  , "<ex:homePage rdf:resource=\"http://purl.org/net/dajobe/\"/>"
  , "</rdf:Description>"
  , "</rdf:RDF>"
  ]

example12 :: Text
example12 = T.pack $ unlines
  [ "<?xml version=\"1.0\"?>"
  , "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\""
  , "         xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
  , "         xmlns:ex=\"http://example.org/stuff/1.0/\">"
  , "  <rdf:Description rdf:about=\"http://www.w3.org/TR/rdf-syntax-grammar\""
  , "   dc:title=\"RDF/XML Syntax Specification (Revised)\">"
  , "    <ex:editor rdf:parseType=\"Resource\">"
  , "      <ex:fullName>Dave Beckett</ex:fullName>"
  , "      <ex:homePage rdf:resource=\"http://purl.org/net/dajobe/\"/>"
  , "    </ex:editor>"
  , "  </rdf:Description>"
  , "</rdf:RDF>"
  ]

xmlEg :: Text
xmlEg = T.pack $ unlines
  [ "<?xml version=\"1.0\"?>"
  , "<rdf:RDF"
  , "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\""
  , "xmlns:si=\"https://www.w3schools.com/rdf/\">"
  , "<rdf:Description rdf:about=\"https://www.w3schools.com\">"
  , "<si:title>W3Schools</si:title>"
  , "<si:author>Jan Egil Refsnes</si:author>"
  , "</rdf:Description>"
  , "</rdf:RDF>"
  ]


-- missing in Xmlbf

-- | @'pElement'' p@ runs a 'Parser' @p@ inside a element node and
-- returns a pair with the name of the parsed element and result of
-- @p@. This fails if such element does not exist at the current
-- position.
--
-- Leading whitespace is ignored. If you need to preserve that whitespace for
-- some reason, capture it using 'pText' before using 'pElement''.
--
-- Consumes the element from the parser state.
-- pElement' :: Parser a -> Parser (Text, a)
-- pElement' = liftA2 (,) pName

-- pText' :: TL.Text -> Parser TL.Text
-- pText' t = do
--   let pTextFail = pFail ("Missing text node " <> show t)
--   do t' <- pText
--      if t == t' then pure t
--      else pTextFail
--    <|> pTextFail


-- parser combinators missing in Xmlbf
-- between :: Parser a -> Parser b -> Parser c -> Parser c
-- between open close thing  = open *> thing <* close
--
-- manyTill :: Parser a -> Parser end -> Parser [a]
-- manyTill thing z = many thing <* z

-- pElem :: Text -> Parser Text
-- oneOf :: Parser [a] -> Parser a
-- noneOf :: Parser [a] -> Parser a
