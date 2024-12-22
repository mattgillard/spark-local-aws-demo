ROLE=clouddialogues-kickstart-iot-dev/AdministratorAccess
AWS_BUNDLE_FILE=aws-java-sdk-bundle-1.12.661.jar
HADOOP_AWS_FILE=hadoop-aws-3.3.4.jar
AWS_BUNDLE=1.12.661/$(AWS_BUNDLE_FILE)
HADOOP_AWS=3.3.4/$(HADOOP_AWS_FILE)
CUSTOM_JARS_DIR=./custom-jars
AWS_CLI=docker run --rm -i --env-file ./.env amazon/aws-cli

.PHONY: test spark prepare-env

build:
	docker build -t spark-plotext .

prepare-env: build
	@echo "Assuming role $(ROLE)..."
	@bash -c '. assume $(ROLE) --env'
	@echo "Removing quotes from .env file..."
	sed -i '' 's/^\(.*=\)"\(.*\)"$$/\1\2/' .env

prep-test-data:
	@if [ ! -f movies.json ]; then \
		wget https://raw.githubusercontent.com/prust/wikipedia-movie-data/master/movies.json -P ./;\
		jq -c '.[]' movies.json > movies.ndjson;\
	fi

test: prepare-env prep-test-data
	@echo "Running AWS CLI to get caller identity..."
	$(AWS_CLI) sts get-caller-identity
	$(AWS_CLI) sts get-caller-identity --output json|jq .Account -r > account_id.txt
	$(eval ACCOUNT_ID := $(shell cat account_id.txt))
	echo "account is $(ACCOUNT_ID)" 
	@if [ ! -f bucket_name.txt ]; then \
		$(AWS_CLI) s3 mb s3://$$ACCOUNT_ID-ss-test-data > bucket_name.txt; \
	fi
	$(eval BUCKET_NAME := $(shell cat bucket_name.txt|awk -F': ' '{print $$2}'))
	echo "bucket is $(BUCKET_NAME)" 
	@$(AWS_CLI) s3api head-object \
		--bucket $(BUCKET_NAME) \
		--key movies.ndjson >/dev/null 2>&1 || \
		(echo "Uploading movies.ndjson to bucket" && \
		docker run --rm -i -v ./movies.ndjson:/movies.ndjson --env-file ./.env \
			amazon/aws-cli s3 cp /movies.ndjson s3://$(BUCKET_NAME))

custom-jars:
	@if [ ! -d $(CUSTOM_JARS_DIR) ]; then \
	  mkdir $(CUSTOM_JARS_DIR); \
	fi
	@echo "Checking for required JAR files..."
	@if [ ! -f $(CUSTOM_JARS_DIR)/$(AWS_BUNDLE_FILE) ]; then \
	  echo "Downloading $(AWS_BUNDLE_FILE)..."; \
	  wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/$(AWS_BUNDLE) -P ./$(CUSTOM_JARS_DIR); \
	fi
	@if [ ! -f $(CUSTOM_JARS_DIR)/$(HADOOP_AWS_FILE) ]; then \
	  echo "Downloading $(HADOOP_AWS_FILE)..."; \
	  wget https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/$(HADOOP_AWS) -P ./$(CUSTOM_JARS_DIR); \
	fi

spark-int: prepare-env custom-jars
	@echo "Starting PySpark with custom JARs..."
	docker run -it \
	  -v $(CUSTOM_JARS_DIR):/custom-jars \
	  -v $(shell pwd):/app \
	  --env-file ./.env \
	  spark-plotext \
	  /opt/spark/bin/pyspark \
	  --jars "/custom-jars/$(AWS_BUNDLE_FILE),/custom-jars/$(HADOOP_AWS_FILE)" \
	  --conf "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem" 

spark-test: prepare-env custom-jars
	@echo "Starting PySpark submit test job.."
	$(eval BUCKET_NAME := $(shell cat bucket_name.txt|awk -F': ' '{print $$2}'))
	echo "bucket is $(BUCKET_NAME)" 
	docker run -it \
	  -v $(CUSTOM_JARS_DIR):/custom-jars \
	  -v $(shell pwd)/app:/app \
	  --env-file ./.env \
	  spark-plotext \
	  /opt/spark/bin/spark-submit \
	  --jars "/custom-jars/$(AWS_BUNDLE_FILE),/custom-jars/$(HADOOP_AWS_FILE)" \
	  --conf "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem" /app/test.py $(BUCKET_NAME)

#spark:3.5.3 \
