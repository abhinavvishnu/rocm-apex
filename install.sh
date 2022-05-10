python3 setup.py clean --all
#python3 setup.py install --bnp  2>&1 | tee output.log
pip install -v --disable-pip-version-check --no-cache-dir --global-option="--bnp" ./ 2>&1 | tee output.log
