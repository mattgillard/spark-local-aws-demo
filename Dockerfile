# Option 1: Create a custom Dockerfile
FROM spark:3.5.3

USER root

# Install python dependencies
RUN pip3 install plotext

USER spark
