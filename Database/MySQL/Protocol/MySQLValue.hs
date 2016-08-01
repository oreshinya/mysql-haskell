{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Database.MySQL.Protocol.MySQLValue
Description : Text and binary protocol
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

This module provide

-}


module Database.MySQL.Protocol.MySQLValue where

import Control.Monad
import qualified Data.ByteString.Lex.Integral   as LexInt
import qualified Data.ByteString.Lex.Fractional as LexFrac
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Char8 as BC
import Data.Scientific (Scientific)
import Data.ByteString.Builder.Scientific (scientificBuilder)
import qualified Blaze.Text as Textual
import qualified Data.Bits as Bit
import Data.Bits ((.|.))
import Data.Fixed (Pico)
import Data.Word
import Data.Int
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.LocalTime (LocalTime(..), TimeOfDay(..))
import Data.Binary.Get
import Data.Binary.Put
import Database.MySQL.Protocol.ColumnDef
import Database.MySQL.Protocol.Packet

--------------------------------------------------------------------------------
-- | data type mapping between MySQL values and haskell values.
data MySQLValue
    = MySQLDecimal       !Scientific   -- ^ DECIMAL, NEWDECIMAL
    | MySQLInt8U         !Word8        -- ^ Unsigned TINY
    | MySQLInt8          !Int8         -- ^ TINY
    | MySQLInt16U        !Word16       -- ^ Unsigned SHORT
    | MySQLInt16         !Int16        -- ^ SHORT
    | MySQLInt32U        !Word32       -- ^ Unsigned LONG, INT24
    | MySQLInt32         !Int32        -- ^ LONG, INT24
    | MySQLInt64U        !Word64       -- ^ Unsigned LONGLONG
    | MySQLInt64         !Int64        -- ^ LONGLONG
    | MySQLFloat         !Float        -- ^ IEEE 754 single precision format
    | MySQLDouble        !Double       -- ^ IEEE 754 double precision format
    | MySQLYear          !Word16       -- ^ YEAR
    | MySQLDateTime      !LocalTime
    | MySQLDate          !Day
    | MySQLTime          !TimeOfDay
    | MySQLBytes         !ByteString
    | MySQLText          !Text
    | MySQLNull
  deriving (Show, Eq)

getMySQLValueType :: MySQLValue -> (FieldType, Word8)
getMySQLValueType (MySQLDecimal      _)  = (MYSQL_TYPE_DECIMAL  , 0x00)
getMySQLValueType (MySQLInt8U        _)  = (MYSQL_TYPE_LONG     , 0x01)
getMySQLValueType (MySQLInt8         _)  = (MYSQL_TYPE_LONG     , 0x00)
getMySQLValueType (MySQLInt16U       _)  = (MYSQL_TYPE_LONGLONG , 0x01)
getMySQLValueType (MySQLInt16        _)  = (MYSQL_TYPE_LONGLONG , 0x00)
getMySQLValueType (MySQLInt32U       _)  = (MYSQL_TYPE_LONGLONG , 0x01)
getMySQLValueType (MySQLInt32        _)  = (MYSQL_TYPE_LONGLONG , 0x00)
getMySQLValueType (MySQLInt64U       _)  = (MYSQL_TYPE_LONGLONG , 0x01)
getMySQLValueType (MySQLInt64        _)  = (MYSQL_TYPE_LONGLONG , 0x00)
getMySQLValueType (MySQLFloat        _)  = (MYSQL_TYPE_FLOAT    , 0x00)
getMySQLValueType (MySQLDouble       _)  = (MYSQL_TYPE_DOUBLE   , 0x00)
getMySQLValueType (MySQLYear         _)  = (MYSQL_TYPE_YEAR     , 0x00)
getMySQLValueType (MySQLDateTime     _)  = (MYSQL_TYPE_DATETIME , 0x00)
getMySQLValueType (MySQLDate         _)  = (MYSQL_TYPE_DATE     , 0x00)
getMySQLValueType (MySQLTime         _)  = (MYSQL_TYPE_TIME     , 0x00)
getMySQLValueType (MySQLBytes        _)  = (MYSQL_TYPE_BLOB     , 0x00)
getMySQLValueType (MySQLText         _)  = (MYSQL_TYPE_STRING   , 0x00)
getMySQLValueType MySQLNull              = (MYSQL_TYPE_NULL     , 0x00)

--------------------------------------------------------------------------------
-- | Text protocol decoder
getTextField :: ColumnDef -> Get MySQLValue
getTextField f
    | t == MYSQL_TYPE_NULL              = pure MySQLNull
    | t == MYSQL_TYPE_DECIMAL
        || t == MYSQL_TYPE_NEWDECIMAL   = feedLenEncBytes t MySQLDecimal fracLexer
    | t == MYSQL_TYPE_TINY              = if isUnsigned then feedLenEncBytes t MySQLInt8U intLexer
                                                        else feedLenEncBytes t MySQLInt8 intLexer
    | t == MYSQL_TYPE_SHORT             = if isUnsigned then feedLenEncBytes t MySQLInt16U intLexer
                                                        else feedLenEncBytes t MySQLInt16 intLexer
    | t == MYSQL_TYPE_LONG
        || t == MYSQL_TYPE_INT24        = if isUnsigned then feedLenEncBytes t MySQLInt32U intLexer
                                                        else feedLenEncBytes t MySQLInt32 intLexer
    | t == MYSQL_TYPE_LONGLONG          = if isUnsigned then feedLenEncBytes t MySQLInt64U intLexer
                                                        else feedLenEncBytes t MySQLInt64 intLexer
    | t == MYSQL_TYPE_FLOAT             = feedLenEncBytes t MySQLFloat fracLexer
    | t == MYSQL_TYPE_DOUBLE            = feedLenEncBytes t MySQLDouble fracLexer
    | t == MYSQL_TYPE_YEAR              = feedLenEncBytes t MySQLYear intLexer
    | t == MYSQL_TYPE_TIMESTAMP
        || t == MYSQL_TYPE_DATETIME
        || t == MYSQL_TYPE_TIMESTAMP2
        || t == MYSQL_TYPE_DATETIME2    = feedLenEncBytes t MySQLDateTime $ \ bs ->
                                            LocalTime <$> dateParser bs <*> timeParser (B.drop 11 bs)
    | t == MYSQL_TYPE_DATE
        || t == MYSQL_TYPE_NEWDATE      = feedLenEncBytes t MySQLDate dateParser
    | t == MYSQL_TYPE_TIME
        || t == MYSQL_TYPE_TIME2        = feedLenEncBytes t MySQLTime timeParser
    | t == MYSQL_TYPE_GEOMETRY          = MySQLBytes <$> getLenEncBytes
    | t == MYSQL_TYPE_VARCHAR
        || t == MYSQL_TYPE_BIT
        || t == MYSQL_TYPE_ENUM
        || t == MYSQL_TYPE_SET
        || t == MYSQL_TYPE_TINY_BLOB
        || t == MYSQL_TYPE_MEDIUM_BLOB
        || t == MYSQL_TYPE_LONG_BLOB
        || t == MYSQL_TYPE_BLOB
        || t == MYSQL_TYPE_VAR_STRING
        || t == MYSQL_TYPE_STRING       = (if isText then MySQLText . T.decodeUtf8 else MySQLBytes) <$> getLenEncBytes
  where
    t = columnType f
    isUnsigned = flagUnsigned (columnFlags f)
    isText = columnCharSet f /= 63
    intLexer bs = fst <$> LexInt.readSigned LexInt.readDecimal bs
    fracLexer bs = fst <$> LexFrac.readSigned LexFrac.readDecimal bs
    dateParser bs = do
        (yyyy, rest) <- LexInt.readDecimal bs
        (mm, rest') <- LexInt.readDecimal (B.tail rest)
        (dd, _) <- LexInt.readDecimal (B.tail rest')
        return (fromGregorian yyyy mm dd)

    timeParser bs = do
        (hh, rest) <- LexInt.readDecimal bs
        (mm, rest') <- LexInt.readDecimal (B.tail rest)
        (ss, _) <- LexFrac.readDecimal (B.tail rest')
        return (TimeOfDay hh mm ss)

    feedLenEncBytes typ con parser = do
        bs <- getLenEncBytes
        if B.null bs
            then return MySQLNull
            else case parser bs of
                Just v -> return (con v)
                Nothing -> fail $ "Database.MySQL.MySQLValue: parsing " ++ show typ ++ " failed, input: " ++ BC.unpack bs

--------------------------------------------------------------------------------
-- | Text protocol encoder
putTextField :: MySQLValue -> Put
putTextField (MySQLDecimal    n) = putBuilder (scientificBuilder n)
putTextField (MySQLInt8U      n) = putBuilder (Textual.integral n)
putTextField (MySQLInt8       n) = putBuilder (Textual.integral n)
putTextField (MySQLInt16U     n) = putBuilder (Textual.integral n)
putTextField (MySQLInt16      n) = putBuilder (Textual.integral n)
putTextField (MySQLInt32U     n) = putBuilder (Textual.integral n)
putTextField (MySQLInt32      n) = putBuilder (Textual.integral n)
putTextField (MySQLInt64U     n) = putBuilder (Textual.integral n)
putTextField (MySQLInt64      n) = putBuilder (Textual.integral n)
putTextField (MySQLFloat      x) = putBuilder (Textual.float x)
putTextField (MySQLDouble     x) = putBuilder (Textual.double x)
putTextField (MySQLYear       n) = putBuilder (Textual.integral n)
putTextField (MySQLDateTime  dt) = putByteString (BC.pack (formatTime defaultTimeLocale "%F %T%Q" dt))
putTextField (MySQLDate       d) = putByteString (BC.pack (formatTime defaultTimeLocale "%F" d))
putTextField (MySQLTime       t) = putByteString (BC.pack (formatTime defaultTimeLocale "%T%Q" t))
putTextField (MySQLBytes     bs) = putByteString bs
putTextField (MySQLText       t) = putByteString (T.encodeUtf8 t)
putTextField MySQLNull           = putWord8 0x79

--------------------------------------------------------------------------------
-- | Text row decoder
getTextRow :: [ColumnDef] -> Get [MySQLValue]
getTextRow fs = forM fs $ \ f -> do
    p <- lookAhead getWord8
    if p == 0x79
    then getWord8 >> return MySQLNull
    else getTextField f

--------------------------------------------------------------------------------
-- | Binary protocol decoder
getBinaryField :: ColumnDef -> Get MySQLValue
getBinaryField f
    | t == MYSQL_TYPE_NULL              = pure MySQLNull
    | t == MYSQL_TYPE_DECIMAL           = fail "Database.MySQL.MySQLValue: unsupported type MYSQL_TYPE_DECIMAL"
    | t == MYSQL_TYPE_NEWDECIMAL        = fail "Database.MySQL.MySQLValue: unsupported type MYSQL_TYPE_NEWDECIMAL"
    | t == MYSQL_TYPE_TINY              = if isUnsigned then MySQLInt8U <$> getWord8
                                                        else MySQLInt8  <$> getInt8
    | t == MYSQL_TYPE_SHORT             = if isUnsigned then MySQLInt16U <$> getWord16le
                                                        else MySQLInt16  <$> getInt16le
    | t == MYSQL_TYPE_LONG
        || t == MYSQL_TYPE_INT24        = if isUnsigned then MySQLInt32U <$> getWord32le
                                                        else MySQLInt32  <$> getInt32le
    | t == MYSQL_TYPE_YEAR              = MySQLYear . fromIntegral <$> getWord16le
    | t == MYSQL_TYPE_LONGLONG          = if isUnsigned then MySQLInt64U <$> getWord64le
                                                        else MySQLInt64  <$> getInt64le
    | t == MYSQL_TYPE_FLOAT             = MySQLFloat  <$> getFloatle
    | t == MYSQL_TYPE_DOUBLE            = MySQLDouble <$> getDoublele
    | t == MYSQL_TYPE_TIMESTAMP
        || t == MYSQL_TYPE_DATETIME     = do n <- getLenEncInt
                                             case n of
                                                0 -> pure $ MySQLDateTime (LocalTime (fromGregorian 0 0 0) (TimeOfDay 0 0 0))
                                                4 -> do
                                                    d <- fromGregorian <$> getYear <*> getInt8' <*> getInt8'
                                                    pure $ MySQLDateTime (LocalTime d (TimeOfDay 0 0 0))
                                                7 -> do
                                                    d <- fromGregorian <$> getYear <*> getInt8' <*> getInt8'
                                                    td <- TimeOfDay <$> getInt8' <*> getInt8' <*> getSecond4
                                                    pure $ MySQLDateTime (LocalTime d td)
                                                11 -> do
                                                    d <- fromGregorian <$> getYear <*> getInt8' <*> getInt8'
                                                    td <- TimeOfDay <$> getInt8' <*> getInt8' <*> getSecond8
                                                    pure $ MySQLDateTime (LocalTime d td)
                                                _ -> fail $ "Database.MySQL.MySQLValue: wrong TIMESTAMP/DATETIME length"


    | t == MYSQL_TYPE_TIMESTAMP2        = fail "Database.MySQL.MySQLValue: unsupported type MYSQL_TYPE_TIMESTAMP2"
    | t == MYSQL_TYPE_DATETIME2         = fail "Database.MySQL.MySQLValue: unsupported type MYSQL_TYPE_DATETIME2"
    | t == MYSQL_TYPE_DATE
        || t == MYSQL_TYPE_NEWDATE      = do n <- getLenEncInt
                                             case n of
                                                0 -> pure $ MySQLDate (fromGregorian 0 0 0)
                                                4 -> MySQLDate <$> (fromGregorian <$> getYear <*> getInt8' <*> getInt8')
                                                _ -> fail $ "Database.MySQL.MySQLValue: wrong DATE/NEWDATE length"

    | t == MYSQL_TYPE_TIME              = do n <- getLenEncInt
                                             case n of
                                                0 -> pure $ MySQLTime (TimeOfDay 0 0 0)
                                                8 -> do
                                                    _ <- getWord8  -- we ignore sign here because 'TimeOfDay' doesn't support,
                                                    _ <- getWord32le   -- we also ignore the day part
                                                    MySQLTime <$> (TimeOfDay <$> getInt8' <*> getInt8' <*> getSecond4)

                                                12 -> do
                                                    _ <- getWord8  -- we ignore sign here because 'TimeOfDay' doesn't support,
                                                    _ <- getWord32le   -- we also ignore the day part
                                                    MySQLTime <$> (TimeOfDay <$> getInt8' <*> getInt8' <*> getSecond8)
                                                _ -> fail $ "Database.MySQL.MySQLValue: wrong TIME length"

    | t == MYSQL_TYPE_TIME2             = fail "Database.MySQL.MySQLValue: unsupported type MYSQL_TYPE_TIME2"
    | t == MYSQL_TYPE_GEOMETRY          = MySQLBytes <$> getLenEncBytes
    | t == MYSQL_TYPE_VARCHAR
        || t == MYSQL_TYPE_BIT
        || t == MYSQL_TYPE_ENUM
        || t == MYSQL_TYPE_SET
        || t == MYSQL_TYPE_TINY_BLOB
        || t == MYSQL_TYPE_MEDIUM_BLOB
        || t == MYSQL_TYPE_LONG_BLOB
        || t == MYSQL_TYPE_BLOB
        || t == MYSQL_TYPE_VAR_STRING
        || t == MYSQL_TYPE_STRING       = if isText then MySQLText . T.decodeUtf8 <$> getLenEncBytes
                                                    else MySQLBytes <$> getLenEncBytes
  where
    t = columnType f
    isUnsigned = flagUnsigned (columnFlags f)
    isText = columnCharSet f /= 63
    -- please check https://github.com/jeremycole/mysql_binlog
    getYear :: Get Integer
    getYear = fromIntegral <$> getWord16le
    getInt8' :: Get Int
    getInt8' = fromIntegral <$> getWord8
    getSecond4 :: Get Pico
    getSecond4 = realToFrac <$> getWord8
    getSecond8 :: Get Pico
    getSecond8 = realToFrac <$> do
        s <- getInt8'
        ms <- fromIntegral <$> getWord32le :: Get Int
        pure $! (realToFrac s + realToFrac ms / 1000 :: Double)

--------------------------------------------------------------------------------
-- | Binary protocol encoder
putBinaryField :: MySQLValue -> Put
putBinaryField (MySQLDecimal    n) = putBuilder (scientificBuilder n)
putBinaryField (MySQLInt32      n) = putInt32le n
putBinaryField (MySQLInt64      n) = putInt64le n
putBinaryField (MySQLDouble     x) = putDoublele x
putBinaryField (MySQLDateTime  (LocalTime date (TimeOfDay h m s))) = do let (yyyy, mm, dd) = toGregorian date
                                                                        let (s', s'') = decodeFloat (realToFrac s :: Double)
                                                                        putWord16le (fromIntegral yyyy)
                                                                        putWord8 (fromIntegral mm)
                                                                        putWord8 (fromIntegral dd)
                                                                        putWord8 (fromIntegral h)
                                                                        putWord8 (fromIntegral m)
                                                                        putWord8 (fromIntegral s')
                                                                        putWord32le (fromIntegral s'')

putBinaryField (MySQLDate   d) = do let (yyyy, mm, dd) = toGregorian d
                                    putWord16le (fromIntegral yyyy)
                                    putWord8 (fromIntegral mm)
                                    putWord8 (fromIntegral dd)


putBinaryField (MySQLTime   (TimeOfDay h m s)) = do let (s', s'') = decodeFloat (realToFrac s :: Double)
                                                    putWord8 (fromIntegral h)
                                                    putWord8 (fromIntegral m)
                                                    putWord8 (fromIntegral s')
                                                    putWord64le (fromIntegral s'')


putBinaryField (MySQLBytes     bs) = putByteString bs
putBinaryField (MySQLText       t) = putByteString (T.encodeUtf8 t)
putBinaryField MySQLNull           = return ()

--------------------------------------------------------------------------------
-- | Binary row encoder
--
-- MySQL use a special null bitmap without offset = 2 here.
getBinaryRow :: [ColumnDef] -> Int -> Get [MySQLValue]
getBinaryRow fields flen = do
    _ <- getWord8           -- 0x00
    let maplen = (flen + 7 + 2) `Bit.shiftR` 3
    nullmap <- getByteString maplen
    go fields nullmap (0 :: Int)
  where
    go [] _       _        = pure []
    go (f:fs) nullmap pos = do
        r <- if isNull nullmap pos
                then return MySQLNull
                else getBinaryField f
        let pos' = pos + 1
        rest <- pos' `seq` go fs nullmap pos'
        return (r `seq` rest `seq` (r : rest))

    isNull nullmap pos =
        let (i, j) = (pos + 2) `divMod` 8
        in (nullmap `B.unsafeIndex` i) `Bit.testBit` j

type BitMap = ByteString

-- | make a nullmap for params without offset.
--
makeNullMap :: [MySQLValue] -> BitMap
makeNullMap values = B.pack (go values 0x00 0)
  where
    go :: [MySQLValue] -> Word8 -> Int -> [Word8]
    go []             byte   8  = [byte]
    go vs             byte   8  = byte : go vs 0x00 0
    go []             byte   _  = [byte]
    go (MySQLNull:vs) byte pos  = let pos' = pos + 1
                                      byte' = byte .|. Bit.bit pos
                                  in pos' `seq` byte' `seq` go vs byte' pos'

    go (_        :vs) byte pos = let pos' = pos + 1 in pos' `seq` go vs byte pos'
