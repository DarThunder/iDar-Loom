local krng = {}

local rng_state = {
    key = nil,
    counter = 0,
    buffer = ""
}

local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
}
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local MOD32 = 0x100000000
local B = 64

local function to_u32(x) return x % 2^32 end

local function word_to_bytes_le(w)
    w = to_u32(w)
    local b1 = w % 256
    local b2 = math.floor(w / 256) % 256
    local b3 = math.floor(w / 65536) % 256
    local b4 = math.floor(w / 16777216) % 256
    return string.char(b1, b2, b3, b4)
end

local function bytes_to_word_le(s, i)
    i = i or 1
    local b1, b2, b3, b4 = string.byte(s, i, i+3)
    return to_u32(b1 + b2*256 + b3*65536 + b4*16777216)
end

local function rotl32(x, n)
    x = to_u32(x)
    n = n % 32
    return to_u32(bit32.lshift(x, n) + bit32.rshift(x, 32 - n))
end

local function rotr32(value, bits)
    value = value % MOD32
    local r = (bit32.rshift(value, bits) + bit32.lshift(value, 32 - bits)) % MOD32
    return r
end

local function to32(x)
    return x % MOD32
end

local function sha256_compress(chunk, H_copy)
    local W = {}
    for i = 1, 16 do
        W[i] = to32(chunk[i] or 0)
    end
    for i = 17, 64 do
        local w15 = W[i-15]
        local w2  = W[i-2]
        local s0 = bit32.bxor(bit32.bxor(rotr32(w15, 7), rotr32(w15, 18)), bit32.rshift(w15, 3))
        local s1 = bit32.bxor(bit32.bxor(rotr32(w2, 17), rotr32(w2, 19)), bit32.rshift(w2, 10))
        W[i] = to32(W[i-16] + s0 + W[i-7] + s1)
    end

    local a, b, c, d, e, f, g, h = table.unpack(H_copy)

    for i = 1, 64 do
        local S1 = bit32.bxor(bit32.bxor(rotr32(e, 6), rotr32(e, 11)), rotr32(e, 25))
        local ch = bit32.bxor(bit32.band(e,f), bit32.band(bit32.bnot(e), g))
        local temp1 = to32(h + S1 + ch + K[i] + W[i])
        local S0 = bit32.bxor(bit32.bxor(rotr32(a, 2), rotr32(a, 13)), rotr32(a, 22))
        local maj = bit32.bxor(bit32.bxor(bit32.band(a, b), bit32.band(a, c)), bit32.band(b, c))
        local temp2 = to32(S0 + maj)

        h = g
        g = f
        f = e
        e = to32(d + temp1)
        d = c
        c = b
        b = a
        a = to32(temp1 + temp2)
    end

    local t = {a,b,c,d,e,f,g,h}
    for i = 1, 8 do
        H_copy[i] = to32(H_copy[i] + t[i])
    end
end

local function sha256(message)
    local message_len = #message
    local padded_message = message .. "\128"
    while (#padded_message % 64) ~= 56 do
        padded_message = padded_message .. "\0"
    end

    padded_message = padded_message .. string.pack(">I8", message_len * 8)

    local H_copy = {table.unpack(H)}
    for pos = 1, #padded_message, 64 do
        local block = padded_message:sub(pos, pos + 63)
        local a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p = string.unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", block)
        local chunk = {a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p}
        sha256_compress(chunk, H_copy)
    end

    local digest_hex = ""
    local digest_bin = ""
    for i = 1, 8 do
        digest_bin = digest_bin .. string.pack(">I4", H_copy[i]) 
        digest_hex = digest_hex .. string.format("%08x", H_copy[i])
    end
    return digest_hex, digest_bin
end

local function quarter_round(state, a, b, c, d)
    state[a] = to_u32(state[a] + state[b]); state[d] = bit32.bxor(state[d], state[a]); state[d] = rotl32(state[d], 16)
    state[c] = to_u32(state[c] + state[d]); state[b] = bit32.bxor(state[b], state[c]); state[b] = rotl32(state[b], 12)
    state[a] = to_u32(state[a] + state[b]); state[d] = bit32.bxor(state[d], state[a]); state[d] = rotl32(state[d], 8)
    state[c] = to_u32(state[c] + state[d]); state[b] = bit32.bxor(state[b], state[c]); state[b] = rotl32(state[b], 7)
end

local function chacha20_block(key32, counter, nonce12)
    local constants = {
        bytes_to_word_le("expa"),
        bytes_to_word_le("nd 3"),
        bytes_to_word_le("2-by"),
        bytes_to_word_le("te k"),
    }

    local state = {}
    for i = 1,4 do state[i] = constants[i] end
    for i = 1,8 do
        local offset = (i-1)*4 + 1
        state[4 + i] = bytes_to_word_le(key32, offset)
    end
    state[13] = to_u32(counter)
    state[14] = bytes_to_word_le(nonce12, 1)
    state[15] = bytes_to_word_le(nonce12, 5)
    state[16] = bytes_to_word_le(nonce12, 9)

    local working = {}
    for i = 1, 16 do working[i] = state[i] end

    for _ = 1, 10 do
        quarter_round(working, 1, 5, 9, 13)
        quarter_round(working, 2, 6, 10, 14)
        quarter_round(working, 3, 7, 11, 15)
        quarter_round(working, 4, 8, 12, 16)
        quarter_round(working, 1, 6, 11, 16)
        quarter_round(working, 2, 7, 12, 13)
        quarter_round(working, 3, 8, 9, 14)
        quarter_round(working, 4, 5, 10, 15)
    end

    local out = {}
    for i = 1, 16 do
        local w = to_u32(working[i] + state[i])
        out[#out + 1] = word_to_bytes_le(w)
    end

    return table.concat(out)
end

local function xor_strings(a, b)
    local res = {}
    local n = math.min(#a, #b)
    for i = 1, n do
        res[i] = string.char(bit32.bxor(string.byte(a, i), string.byte(b, i)))
    end
    return table.concat(res)
end

local function derive_key(secret)
    local _, bin = sha256(secret)
    return bin
end

local function operate(message, secret, nonce)
    if not message or not secret or not nonce then return nil end
    if #nonce ~= 12 then error("nonce must be 12 bytes") end

    local key = derive_key(secret)
    local out = {}
    local counter = 0
    local pos = 1

    while pos <= #message do
        local keystream = chacha20_block(key, counter, nonce)
        local block = message:sub(pos, pos + 63)
        local x = xor_strings(block, keystream)
        out[#out + 1] = x
        pos = pos + #block
        counter = (counter + 1) % 2^32
    end

    return table.concat(out)
end

local function encrypt(message, secret, nonce)
    return operate(message, secret, nonce)
end

local pools = {}
for i = 1, 32 do pools[i] = "" end
local reseed_count = 0
local pool_index = 0

local function fortuna_reseed()
    reseed_count = reseed_count + 1
    local material = ""

    for i = 1, 32 do
        if reseed_count % (2^i) == 0 then
            local _, h = sha256(pools[i])
            material = material .. h
            pools[i] = ""
        end
    end

    local _, new_key = sha256(rng_state.key .. material)
    rng_state.key = new_key
    rng_state.counter = 0
end

function krng.add_entropy(event_data)
    pool_index = (pool_index % 32) + 1
    pools[pool_index] = pools[pool_index] .. event_data

    if #pools[1] >= 64 then
        fortuna_reseed()
    end
end

local function gather_entropy()
    local samples = {}

    table.insert(samples, tostring(os.epoch("utc")))
    table.insert(samples, tostring(os.epoch("ingame")))
    table.insert(samples, tostring(os.epoch("local")))

    for _ = 1, 3 do
        local t1 = os.clock()
        for _ = 1, math.random(50, 200) do
            math.random()
        end
        local t2 = os.clock()
        table.insert(samples, tostring(math.floor((t2-t1) * 1e9)))
    end

    table.insert(samples, tostring(os.getComputerID()))

    local _, seed1 = sha256(table.concat(samples, ":"))
    local _, seed2 = sha256(seed1 .. table.concat(samples, "|"))
    local _, seed3 = sha256(seed2 .. seed1)

    return seed3
end

local function reseed_rng()
    local raw = gather_entropy()
    if rng_state.key then
        raw = raw .. rng_state.key
    end

    local _, bin_hash = sha256(raw)
    rng_state.key = bin_hash
    rng_state.counter = 0
end

function krng.read_random_bytes(num_bytes)
    if not rng_state.key then reseed_rng() end

    while #rng_state.buffer < num_bytes do
        local nonce = string.rep("\0", 8) .. string.pack(">I4", rng_state.counter)

        local zeros = string.rep("\0", 64)
        local keystream_block = encrypt(zeros, rng_state.key, nonce)

        rng_state.buffer = rng_state.buffer .. keystream_block
        rng_state.counter = rng_state.counter + 1

        if rng_state.counter % 1024 == 0 then reseed_rng() end
    end

    local result = rng_state.buffer:sub(1, num_bytes)
    rng_state.buffer = rng_state.buffer:sub(num_bytes + 1)

    return result
end

krng.read_random_bytes(1)

return krng