create or replace task {{ env_var('environment') }}_INGESTION_DB.INOVA_BASE.TASK_MERGESTAGETOBASE
	warehouse=DEVELOPER_WH
	schedule='USING CRON 00 11 * * * America/Los_Angeles'
	as CALL {{ env_var('environment') }}_INGESTION_DB.MASTER.MERGESTAGETOBASE(0,''{{ env_var('environment') }}'',CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,10);