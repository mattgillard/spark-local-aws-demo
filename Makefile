ROLE=clouddialogues-kickstart-iot-dev/AdministratorAccess
AWS_REGION ?= ap-southeast-2

HADOOP_AWS_FILE=hadoop-aws-3.3.4.jar
AWS_SDK2_BUNDLE_FILE=bundle-2.29.38.jar
AWS_S3_TABLES_FILE=s3-tables-catalog-for-iceberg-0.1.3.jar
ICEBERG_RUNTIME_FILE=iceberg-spark-runtime-3.5_2.12-1.6.1.jar
APACHE_COMMONS_FILE=commons-configuration2-2.11.0.jar
CAFFEINE_FILE=caffeine-3.1.8.jar
AWS_BUNDLE_FILE=aws-java-sdk-bundle-1.12.661.jar
AWS_BUNDLE=https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.661/$(AWS_BUNDLE_FILE)
HADOOP_AWS=https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/$(HADOOP_AWS_FILE)
AWS_SDK2_BUNDLE=https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.29.38/$(AWS_SDK2_BUNDLE_FILE)
CAFFEINE=https://repo1.maven.org/maven2/com/github/ben-manes/caffeine/caffeine/3.1.8/$(CAFFEINE_FILE)
APACHE_COMMONS=https://repo1.maven.org/maven2/org/apache/commons/commons-configuration2/2.11.0/$(APACHE_COMMONS_FILE)
AWS_S3_TABLES=https://repo1.maven.org/maven2/software/amazon/s3tables/s3-tables-catalog-for-iceberg/0.1.3/$(AWS_S3_TABLES_FILE)
ICEBERG_RUNTIME=https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.6.1/$(ICEBERG_RUNTIME_FILE)

JAR_FILES = \
						$(AWS_BUNDLE_FILE)%$(AWS_BUNDLE) \
						$(HADOOP_AWS_FILE)%$(HADOOP_AWS) \
						$(AWS_SDK2_BUNDLE_FILE)%$(AWS_SDK2_BUNDLE) \
						$(CAFFEINE_FILE)%$(CAFFEINE) \
						$(APACHE_COMMONS_FILE)%$(APACHE_COMMONS) \
						$(AWS_S3_TABLES_FILE)%$(AWS_S3_TABLES) \
						$(ICEBERG_RUNTIME_FILE)%$(ICEBERG_RUNTIME)

CUSTOM_JARS_DIR=./custom-jars
AWS_CLI=docker run --rm -i --env-file ./.env amazon/aws-cli

.PHONY: test spark prepare-env custom-jars

build:
	docker build -t spark-plotext .

prepare-env: build
	@echo "Assuming role $(ROLE)..."
	@bash -c '. assume $(ROLE) --region $(AWS_REGION) --env'
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
	echo "Checking for required JAR files..."
	@for jar in $(JAR_FILES); do \
		file=$$(echo $$jar | cut -d% -f1); \
		url=$$(echo $$jar | cut -d% -f2); \
	  if [ ! -f $(CUSTOM_JARS_DIR)/$$file ]; then \
	    echo "Downloading $$file from $$url..."; \
	    wget $$url -P $(CUSTOM_JARS_DIR); \
	  fi; \
	done
#	@if [ ! -d $(CUSTOM_JARS_DIR) ]; then \
#	  mkdir $(CUSTOM_JARS_DIR); \
#	fi
#	@echo "Checking for required JAR files..."
#	@if [ ! -f $(CUSTOM_JARS_DIR)/$(AWS_BUNDLE_FILE) ]; then \
#	  echo "Downloading $(AWS_BUNDLE_FILE)..."; \
#	  wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/$(AWS_BUNDLE) -P ./$(CUSTOM_JARS_DIR); \
#	fi
#	@if [ ! -f $(CUSTOM_JARS_DIR)/$(HADOOP_AWS_FILE) ]; then \
#	  echo "Downloading $(HADOOP_AWS_FILE)..."; \
#	  wget https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/$(HADOOP_AWS) -P ./$(CUSTOM_JARS_DIR); \
#	fi

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

spark-test: prepare-env custom-jars test
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

spark-s3tables: prepare-env custom-jars
	@echo "Starting spark in interactive mode for s3 tables access..."
	$(eval ACCOUNT_ID := $(shell cat account_id.txt))
	echo "account is $(ACCOUNT_ID)" 
	docker run -it \
	  -v $(CUSTOM_JARS_DIR):/custom-jars \
	  -v $(shell pwd):/app \
	  --env-file ./.env \
	  spark-plotext \
	  /opt/spark/bin/pyspark \
	  --jars "/custom-jars/$(AWS_SDK2_BUNDLE_FILE),/custom-jars/$(AWS_S3_TABLES_FILE),/custom-jars/$(ICEBERG_RUNTIME_FILE),/custom-jars/commons-configuration2-2.11.0.jar,/custom-jars/caffeine-3.1.8.jar" \
		--conf spark.sql.catalog.s3tablesbucket=org.apache.iceberg.spark.SparkCatalog \
		--conf spark.sql.catalog.s3tablesbucket.catalog-impl=software.amazon.s3tables.iceberg.S3TablesCatalog \
		--conf spark.sql.catalog.s3tablesbucket.warehouse=arn:aws:s3tables:us-west-2:$(ACCOUNT_ID):bucket/test \
		--conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions

#spark:3.5.3 \
