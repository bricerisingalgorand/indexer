#!/usr/bin/env bash

# The cleanup hook ensures these containers are removed when the script exits.
POSTGRES_CONTAINER=test-container

NET=localhost:8981
CURL_TEMPFILE=curl_out.txt
PIDFILE=testindexerpidfile
CONNECTION_STRING="host=localhost user=algorand password=algorand dbname=DB_NAME_HERE port=5434 sslmode=disable"

###################
## Print Helpers ##
###################
function print_alert() {
  printf "\n=====\n===== $1\n=====\n"
}

##################
## Test Helpers ##
##################

function fail_and_exit {
  print_alert "Failed test - $1 ($2): $3"
  exit 1
}

function base_call() {
  curl -o "$CURL_TEMPFILE" -w "%{http_code}" -q -s "$NET$1"
}

function wait_for_ready() {
  local n=0

  set +e
  local READY
  until [ "$n" -ge 20 ] || [ ! -z $READY ]
  do
    curl -q -s "$NET/health" | grep '"is-migrating":false' > /dev/null 2>&1 && READY=1
    n=$((n+1))
    sleep 1
  done
  set -e

  if [ -z $READY ]; then
    echo "Error: timed out waiting for db to become available."
    curl "$NET/health"
    exit 1
  fi
}

# $1 - test description.
# $2 - query
# $3 - expected status code
# $4 - substring that should be in the response
function call_and_verify {
  local CODE

  set +e
  CODE=$(base_call "$2")
  if [[ $? != 0 ]]; then
    echo "ERROR"
    cat $CURL_TEMPFILE
    return
    fail_and_exit "$1" "$2" "curl had a non-zero exit code."
  fi
  set -e

  RES=$(cat "$CURL_TEMPFILE")
  if [[ "$CODE" != "$3" ]]; then
    fail_and_exit "$1" "$2" "unexpected HTTP status code expected $3 (actual $CODE): $RES"
  fi
  if [[ "$RES" != *"$4"* ]]; then
    fail_and_exit "$1" "$2" "unexpected response. should contain '$4', actual: $RES"
  fi

  print_alert "Passed test: $1"
}

#####################
## Indexer Helpers ##
#####################

# Suppresses output if the command succeeds
# $1 command to run
function suppress() {
  /bin/rm --force /tmp/suppress.out 2> /dev/null
  ${1+"$@"} > /tmp/suppress.out 2>&1 || cat /tmp/suppress.out
  /bin/rm /tmp/suppress.out
}

# $1 - postgres dbname
function start_indexer() {
  ALGORAND_DATA= ../cmd/algorand-indexer/algorand-indexer daemon \
    -S $NET \
    -P "${CONNECTION_STRING/DB_NAME_HERE/$1}" \
    --pidfile $PIDFILE > /dev/null 2>&1 &
}


# $1 - postgres dbname
# $2 - e2edata tar.bz2 archive
function start_indexer_with_blocks() {
  if [ ! -f $2 ]; then
    echo "Cannot find $2"
    exit
  fi

  create_db $1

  local TEMPDIR=$(mktemp -d -t ci-XXXXXXX)
  tar -xf "$2" -C $TEMPDIR

  ALGORAND_DATA= ../cmd/algorand-indexer/algorand-indexer import \
    -P "${CONNECTION_STRING/DB_NAME_HERE/$1}" \
    --genesis "$TEMPDIR/algod/genesis.json" \
    $TEMPDIR/blocktars/*

  rm -rf $TEMPDIR

  start_indexer $1
}

function kill_indexer() {
  if test -f "$PIDFILE"; then
    kill -9 $(cat "$PIDFILE") > /dev/null 2>&1 || true
    rm $PIDFILE
  fi
}

####################
## Docker helpers ##
####################

# $1 - name of docker container to kill.
function kill_container() {
  print_alert "Killing container - $1"
  docker rm -f $1 > /dev/null 2>&1 || true
}

function start_postgres() {
  if [ $# -ne 0 ]; then
    print_alert "Unexpected number of arguments to start_postgres."
    exit 1
  fi

  local CONTAINER_NAME=$POSTGRES_CONTAINER

  # Cleanup from last time
  kill_container $CONTAINER_NAME

  print_alert "Starting - $CONTAINER_NAME"
  # Start postgres container...
  docker run \
    -d \
    --name $CONTAINER_NAME \
    -e POSTGRES_USER=algorand \
    -e POSTGRES_PASSWORD=algorand \
    -e PGPASSWORD=algorand \
    -p 5434:5432 \
    postgres

  sleep 5

  print_alert "Started - $CONTAINER_NAME"
}

# $1 - postgres database name.
function create_db() {
  local CONTAINER_NAME=$POSTGRES_CONTAINER
  local DATABASE=$1

  # Create DB
  docker exec -it $CONTAINER_NAME psql -Ualgorand -c "create database $DATABASE"
}

# $1 - postgres database name.
# $2 - pg_dump file to import into the database.
function initialize_db() {
  local CONTAINER_NAME=$POSTGRES_CONTAINER
  local DATABASE=$1
  local DUMPFILE=$2
  print_alert "Initializing database ($DATABASE) with $DUMPFILE"

  # load some data into it.
  create_db $DATABASE
  #docker exec -i $CONTAINER_NAME psql -Ualgorand -c "\\l"
  docker exec -i $CONTAINER_NAME psql -Ualgorand -d $DATABASE < $DUMPFILE > /dev/null 2>&1
}

function cleanup() {
  kill_container $POSTGRES_CONTAINER
  rm $CURL_TEMPFILE > /dev/null 2>&1 || true
  kill_indexer
}
