import sys
from pyspark.sql import SparkSession, functions as F
from pyspark.sql.types import *
import plotext as plt

if len(sys.argv) < 2:
        print("Usage: python test.py <BUCKET_NAME>")
        sys.exit(1)

bucket_name = sys.argv[1]
print(f"Bucket name received: {bucket_name}")

# Initialize Spark Session if not already initialized
spark = SparkSession.builder \
    .appName("Movies Analysis") \
    .getOrCreate()

# Read the JSON file from S3
try:
    df = spark.read.json(f"s3a://{bucket_name}/movies.ndjson")
    print(f"Successfully loaded data. Total records: {df.count()}")
except Exception as e:
    print(f"Error loading data: {str(e)}")
    raise

# Create decade bins
def get_decade(year):
    return (year // 10) * 10

get_decade_udf = F.udf(get_decade, LongType())

# Process data
decade_genre_counts = (df
    .withColumn("decade", get_decade_udf(F.col("year")))
    .withColumn("genre", F.explode("genres"))
    .groupBy("decade", "genre")
    .agg(F.count("*").alias("movie_count"))
    .orderBy("decade", "genre")
)

# Collect the data we need for plotting
data = decade_genre_counts.collect()

# Get unique decades and top 5 genres (to keep the plot readable)
decades = sorted(set(row['decade'] for row in data))
genre_totals = {}
for row in data:
    genre_totals[row['genre']] = genre_totals.get(row['genre'], 0) + row['movie_count']
top_genres = sorted(genre_totals.items(), key=lambda x: x[1], reverse=True)[:5]
top_genre_names = [g[0] for g in top_genres]

# Create a dictionary to store genre data
genre_data = {}
for genre in top_genre_names:
    genre_data[genre] = []
    for decade in decades:
        count = next((row['movie_count'] for row in data 
                     if row['decade'] == decade and row['genre'] == genre), 0)
        genre_data[genre].append(count)

# Plot using plotext
plt.clear_data()
plt.clc()
plt.theme('dark')
plt.plot_size(70, 20)  # Adjust plot size

# Plot each genre separately
x_indices = list(range(len(decades)))  # Use indices for x-axis
plt.xticks(x_indices, [str(d) for d in decades])  # Set decade labels

for genre in top_genre_names:
#    plt.scatter(x_indices, genre_data[genre], label=genre)
    plt.plot(x_indices, genre_data[genre], label=genre)

plt.title("Movies by Decade and Genre (Top 5 Genres)")
plt.xlabel("Decade")
plt.ylabel("Number of Movies")
plt.grid(True)
plt.show()

# Print summary statistics
print("\nTop 5 genres by total movie count:")
print("\n{:<15} {:<10}".format("Genre", "Total Movies"))
print("-" * 25)
for genre, total in top_genres:
    print("{:<15} {:<10}".format(genre, total))

# Print totals by decade
print("\nTotal movies by decade:")
print("\n{:<10} {:<10}".format("Decade", "Movies"))
print("-" * 20)
decade_totals = decade_genre_counts.groupBy("decade").agg(F.sum("movie_count").alias("total")).orderBy("decade").collect()
for row in decade_totals:
    print("{:<10} {:<10}".format(row['decade'], row['total']))

# Clean up
spark.stop()


