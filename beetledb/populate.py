import sqlite3
import random
import string


# Function to generate random usernames and emails
def generate_random_user():
    username = "".join(random.choices(string.ascii_lowercase, k=8))
    email = username + "@mail.com"
    return (username, email)


conn = sqlite3.connect("test.sqlite3")
cursor = conn.cursor()

N = 100000

users_to_insert = [generate_random_user() for _ in range(N)]

# Use executemany for batch insertion
cursor.executemany("INSERT INTO users (username, email) VALUES (?, ?)", users_to_insert)

# Commit the changes and close the connection
conn.commit()
conn.close()

print(f"Inserted {N} user records successfully.")
