#!/bin/bash

SHA8=$(echo ${GIT_SHA} | cut -c1-8)
echo "SHA8: ${SHA8}"
echo "::set-output name=sha8::${SHA8}"
