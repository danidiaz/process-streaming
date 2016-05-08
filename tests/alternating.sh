#!/bin/bash

for (( i=1; i <= 10000; i++ ))
do
     echo "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
done

for (( i=1; i <= 10000; i++ ))
do
     echo "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE" 1>&2
done

for (( i=1; i <= 10000; i++ ))
do
     echo "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
done

for (( i=1; i <= 10000; i++ ))
do
     echo "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE" 1>&2
done
