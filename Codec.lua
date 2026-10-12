-- Encoding of tables into addon-message-safe text and back:
-- CBOR (C_EncodingUtil) -> deflate -> base64. Returns nil, err on failure.

local _, ns = ...

local E = C_EncodingUtil
local METHOD = Enum.CompressionMethod and Enum.CompressionMethod.Deflate

function ns.Encode(value)
	local ok, cbor = pcall(E.SerializeCBOR, value)
	if not ok then return nil, "cbor: " .. tostring(cbor) end
	local ok2, packed = pcall(E.CompressString, cbor, METHOD)
	if not ok2 then return nil, "compress: " .. tostring(packed) end
	return E.EncodeBase64(packed)
end

function ns.Decode(text)
	local ok, packed = pcall(E.DecodeBase64, text)
	if not ok or not packed then return nil, "base64" end
	local ok2, cbor = pcall(E.DecompressString, packed, METHOD)
	if not ok2 or not cbor then return nil, "decompress" end
	local ok3, value = pcall(E.DeserializeCBOR, cbor)
	if not ok3 then return nil, "cbor" end
	return value
end

-- Sizes of each stage, for the codec spike and status output.
function ns.EncodeSizes(value)
	local cbor = E.SerializeCBOR(value)
	local packed = E.CompressString(cbor, METHOD)
	return #cbor, #packed, #E.EncodeBase64(packed)
end
