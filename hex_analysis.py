# Original data from user
original = "e6 e8 e4 e4 e5 e7 e6 e8 e8 e4 e9 ef e4 e6 e5 e8 e9"

# Remove spaces and convert to bytes
clean_hex = original.replace(" ", "")
bytes_data = bytes.fromhex(clean_hex)

print("Cleaned hex:", clean_hex)
print("Length:", len(bytes_data), "bytes")
print("Bytes as list:", list(bytes_data))
print()

# Try to interpret as UTF-8
try:
    utf8_text = bytes_data.decode('utf-8')
    print("UTF-8 decoded:", repr(utf8_text))
    print("UTF-8 readable:", utf8_text)
except UnicodeDecodeError as e:
    print("UTF-8 decode error:", e)
except Exception as e:
    print("UTF-8 other error:", e)

print()

# Try to interpret as Russian CP1251 (common for Cyrillic text)
try:
    cp1251_text = bytes_data.decode('cp1251')
    print("CP1251 decoded:", repr(cp1251_text))
    print("CP1251 readable:", cp1251_text)
except UnicodeDecodeError as e:
    print("CP1251 decode error:", e)
except Exception as e:
    print("CP1251 other error:", e)