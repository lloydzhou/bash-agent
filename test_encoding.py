# Try to decode the hex values
hex_data = "e6e8e4e4e5e7e6e8e8e4e9efe4e6e5e8e9"

# Convert hex bytes to actual bytes
bytes_data = bytes.fromhex(hex_data)

# Try different encodings
print("UTF-8:", bytes_data.decode('utf-8', errors='replace'))
print("Latin-1:", bytes_data.decode('latin-1'))
print("CP1251:", bytes_data.decode('cp1251', errors='replace'))