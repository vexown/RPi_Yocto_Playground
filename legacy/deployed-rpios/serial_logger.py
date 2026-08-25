import serial
import datetime
import os
import sys

# --- CONFIGURATION ---
PORT = '/dev/ttyUSB0'
BAUD_RATE = 115200
LOG_DIR = '/home/blankmcu/logs'

# Ensure the log directory exists
os.makedirs(LOG_DIR, exist_ok=True)

# Create a unique filename based on the current timestamp
timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
log_filename = os.path.join(LOG_DIR, f"session_{timestamp}.log")

try:
    # Open the serial port
    ser = serial.Serial(PORT, BAUD_RATE, timeout=1)
    
    # Open the log file in append mode
    with open(log_filename, 'a', encoding='utf-8') as log_file:
        log_file.write(f"--- Session started at {datetime.datetime.now()} ---\n")
        log_file.flush()
        
        while True:
            if ser.in_waiting > 0:
                line = ser.readline()
                # Decode bytes to text, ignoring transmission noise errors
                decoded_line = line.decode('utf-8', errors='ignore')
                
                # Write to the file
                log_file.write(decoded_line)
                
                # FORCE saving to SD card immediately so data isn't lost if power drops
                log_file.flush()
                
                # Print to the terminal simultaneously (tee style)
                print(decoded_line, end='', flush=True)

except KeyboardInterrupt:
    print("\nLogging stopped by user.")
    sys.exit(0)
except Exception as e:
    # If something fails (like the USB gets unplugged), log the error
    with open(os.path.join(LOG_DIR, "error.log"), "a") as err_file:
        err_file.write(f"{datetime.datetime.now()}: {str(e)}\n")
    sys.exit(1)
