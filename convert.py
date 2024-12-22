import json

with open("movies.json", "r") as f, open("movies_nd.json", "w") as out:
    data = json.load(f)
    for item in data:
        out.write(json.dumps(item) + "\n")

