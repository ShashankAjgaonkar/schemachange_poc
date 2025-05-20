CREATE OR REPLACE PROCEDURE {{ environment }}_INGESTION_DB.MASTER.MERGESTAGETOBASEPY("dbname" VARCHAR, "schema" VARCHAR, "table" VARCHAR, "PRIMARY_KEYS" ARRAY, "DELIMETER" VARCHAR, "BASE_FOLDER" VARCHAR, "PATTERN" VARCHAR, "BASEUPDATEDDATE" TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(), "PARTNERSK" NUMBER(38,0) DEFAULT -1, "DATE_THRESHOLD" VARCHAR DEFAULT 'None', "DATE_FORMAT" VARCHAR DEFAULT 'None', "HEADER" NUMBER(38,0) DEFAULT 0, "ORDER_BY_COL" VARCHAR DEFAULT 'None')
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'load_from_stage'
EXECUTE AS CALLER
AS '## LATEST CODE
import re
from snowflake.snowpark.types import StructType, StructField, StringType, IntegerType, ArrayType
from datetime import datetime
from snowflake.snowpark.functions import col, row_number, expr, current_timestamp, lit
from snowflake.snowpark.window import Window
from snowflake.snowpark import Row
import time



def merge_into_final(session,source,df,primary_keys,file,partnersk=-1):
    #df.columns = df.columns.str.upper().str.replace(''"'', '''')
    schemaStr = df.columns
    df_new = df.select(
                *schemaStr,
                current_timestamp().alias("BASECREATEDDATE"),
                current_timestamp().alias("BASEUPDATEDDATE"),
                expr("''0''").alias("BASEDELETEDFLAG"),
                current_timestamp().alias("snowflake_created_at"),
                current_timestamp().alias("snowflake_updated_at"),
                expr("''0''").alias("snowflake_deleted_flag"))
    if partnersk != -1:
        df_new = df_new.withColumn("PARTNERSK",lit(partnersk))
        primary_keys.append(''PARTNERSK'')

    df_new.write.mode("overwrite").save_as_table(f''{database_name}.{schema_name}.{source}_Tem'',column_order="name",table_type=''temporary'')
    
    date_cols = [''BASECREATEDDATE'',''BASEUPDATEDDATE'',''BASEDELETEDFLAG'',''SNOWFLAKE_CREATED_AT'',''SNOWFLAKE_UPDATED_AT'',''SNOWFLAKE_DELETED_FLAG'']
    
    business_columns = [col for col in schemaStr if col not in primary_keys and col not in date_cols]  # Exclude primary keys
            # Construct dynamic ON condition for MERGE using primary keys
    on_condition = " AND ".join([f"target.{pk} = source.{pk}" for pk in primary_keys])
    on_condition_cols = ", ".join([f"source.{col}" for col in primary_keys])
    # Check if any business column has changed
    change_condition = " OR ".join([f"COALESCE(target.{col},''0'') <> COALESCE(source.{col},''0'')" for col in business_columns])
            # Merge SQL with SCD Type 2 logic
    
    update_sql = f"""
        -- Step 1: Soft delete existing records if business columns change
        MERGE INTO {database_name}.{schema_name}.{source} AS target
        USING {database_name}.{schema_name}.{source}_Temp AS source
        ON {on_condition} AND target.snowflake_deleted_flag = ''0''
        WHEN MATCHED AND ({change_condition}) THEN
            UPDATE SET
                target.snowflake_deleted_flag = ''0'',
                target.snowflake_updated_at = ''{currenttime}'',
                target.BASEUPDATEDDATE = ''{currenttime}''
        WHEN NOT MATCHED THEN
         INSERT (
        {", ".join(schemaStr)}, BASECREATEDDATE, BASEUPDATEDDATE, BASEDELETEDFLAG,
        snowflake_created_at, snowflake_updated_at, snowflake_deleted_flag
        )
        VALUES (
            {", ".join(["source." + col for col in schemaStr])},
            ''{currenttime}'', 
            ''{currenttime}'', 
            ''0'', 
            ''{currenttime}'',
            ''{currenttime}'',
            ''0'' 
        );
        """
    
    
    insert_sql = f"""
                INSERT INTO {database_name}.{schema_name}.{source}
        ({", ".join(schemaStr)}, BASECREATEDDATE,BASEUPDATEDDATE,BASEDELETEDFLAG, snowflake_created_at, snowflake_updated_at, snowflake_deleted_flag)
        SELECT {", ".join(["source." + col for col in schemaStr])},
            COALESCE(source.t_basecreateddate, ''{currenttime}''),
            ''{currenttime}'',
            ''0'',
            COALESCE(source.t_snowflake_created_at, ''{currenttime}''), -- Preserve created_at
            ''{currenttime}'',
            ''0''
        FROM (
        SELECT source.*,target.basecreateddate as t_basecreateddate,target.snowflake_created_at as t_snowflake_created_at, ROW_NUMBER() OVER (PARTITION BY {on_condition_cols} ORDER BY target.snowflake_updated_at DESC) AS rn
        FROM {database_name}.{schema_name}.{source}_Temp AS source
        INNER JOIN {database_name}.{schema_name}.{source} AS target
        ON {on_condition} and target.SNOWFLAKE_DELETED_FLAG = ''1''
        WHERE ({change_condition}) AND target.snowflake_deleted_flag = ''1''
        AND NOT EXISTS (
        SELECT 1 FROM {database_name}.{schema_name}.{source} target
        where {on_condition} AND target.snowflake_deleted_flag=''0''
        )
        ) source
        WHERE rn = 1;
        ; -- Updated records
                    """

    try:
        start_time = time.time()
        session.sql(''begin transaction'').collect()
        updated_rows = session.sql(update_sql).collect()[0][0]
        print(f"updated rows: {updated_rows}")
        inserted_rows = session.sql(insert_sql).collect()[0][0]
        print(f"inserted rows: {inserted_rows}")

        end_time = time.time()
        run_time = "%.2f" % (end_time-start_time)
        
        session.sql(f"""insert into {{ environment }}_AUDIT_DB.AUDIT.AUDIT_TABLE (LOG_TIMESTAMP, PARTNERSK, FLOW_TYPE, RUN_TIME, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, PROC_NAME, INSERTED_REC_CNT, UPDATED_REC_CNT, STATUS, MESSAGE, FILE_NAME)
                    VALUES (CURRENT_TIMESTAMP, {partnersk}, ''I'',{run_time},''{database_name}'',''{schema_name}'',''{source}'',''MERGESTAGETOBASEPY'',{inserted_rows},{updated_rows},''SUCCESS'',''Successfully merged into the final table'',''{file}'')""").collect()

        session.sql(''commit'').collect()
        return ''Successfully merged into the final table''
    except Exception as e:
        session.sql(''rollback'').collect()
        end_time = time.time()
        run_time = "%.2f" % (end_time-start_time)

        session.sql(f"""insert into {{ environment }}_AUDIT_DB.AUDIT.AUDIT_TABLE (LOG_TIMESTAMP, PARTNERSK, FLOW_TYPE, RUN_TIME, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, PROC_NAME, INSERTED_REC_CNT, UPDATED_REC_CNT, STATUS, MESSAGE,FILE_NAME)
                    VALUES (CURRENT_TIMESTAMP, {partnersk}, ''I'',{run_time},''{database_name}'',''{schema_name}'',''{source}'',''MERGESTAGETOBASEPY'',0,0,''FAILURE'',''{str(e)}'',''{file}'')""").collect()
        return f''Merge failed with Error: {e}''

def drop_duplicates_ordered(df, subset, order_by_col=None, ascending=True):
    """
    Removes duplicates based on specified columns. If order_by_col is provided, it keeps the latest or earliest row.
    :param df: Snowpark DataFrame
    :param subset: List of columns to check for duplicates
    :param order_by_col: Column used for ordering (optional)
    :param ascending: Whether to sort in ascending order (default: False, keeps latest/highest)
    :return: Deduplicated DataFrame
    """
    if order_by_col != ''None'':  # If ordering is specified, use window function
        order = col(order_by_col).asc() if ascending else col(order_by_col).desc()
        window_spec = Window.partition_by(*[col(c) for c in subset]).order_by(order)
        df_with_rn = df.with_column("row_num", row_number().over(window_spec))
        return df_with_rn.filter(col("row_num") == 1).drop("row_num")
    else:  # No ordering column, just use drop_duplicates()
        return df.drop_duplicates(subset)


def isfilesync(session,file_path,table_name,partnersk=-1):
    """
    Check if the given file is already present in the audit table with SUCCESS status
    for the given partner and table name, considering only the last 50 records.
    """
    audit_check_sql = f"""
        SELECT FILE_NAME
        FROM {{ environment }}_AUDIT_DB.AUDIT.AUDIT_TABLE
        WHERE TABLE_NAME = ''{table_name}''
        AND SCHEMA_NAME = ''{schema_name}''
        AND PARTNERSK = {partnersk}
        AND STATUS = ''SUCCESS''
        ORDER BY LOG_TIMESTAMP DESC
        LIMIT 50
    """
    result = session.sql(audit_check_sql).collect()
    audited_files = [row[''FILE_NAME''] for row in result]
    return file_path in audited_files



def load_from_stage(session, dbname, schema, table, primary_keys,delimeter, base_folder, pattern, baseupdateddate, partnersk=-1, date_threshold=None, date_format=None, header=0, order_by_col=None):
    """
    Loads files from Snowflake stage based on dynamic parameters and filters them using a regex pattern and optional date.
    Args:
        session: Snowflake session
        schema: Target schema name
        table: Target table name
        base_folder: Base directory in Snowflake stage
        pattern: Regex pattern to match filenames
        date_threshold: Optional date to filter files
        date_format: Format of the date in the filename provided by the user
        header: Boolean flag indicating if files contain headers
    """
    base_folder = base_folder.replace('' '', ''_'')
    stage_name = ''{{ environment }}_INGESTION_DB.MASTER.SFTP_STAGE''
    list_stage_sql = f"LIST @{stage_name}/{base_folder}/;"
    result = session.sql(list_stage_sql).collect()
    # Compile regex pattern for file matching
    regex = re.compile(pattern)
    global schema_name
    global database_name
    global currenttime

    schema_name = schema
    currenttime = baseupdateddate
    database_name = dbname
    
    valid_files = []
    for row in result:
        file_path = row[''name'']
        match = regex.search(file_path)
        if match:
            # Extract date if user provides a format
            file_date = None
            if date_format != ''None'':
                try:
                    #file_date_str = re.search(date_format, file_path)
                    file_date = datetime.strptime(match.group(1), date_format).date()
                except ValueError:
                    continue  # Skip if date format does not match
            # Validate date if threshold is provided
            if date_threshold != ''None'' and file_date:
                threshold_date = datetime.strptime(date_threshold, date_format).date()
                if file_date >= threshold_date and not isfilesync(session,file_path,table,partnersk):
                    valid_files.append(file_path)

            else:
                valid_files.append(file_path)
            
    if not valid_files:
        session.sql(f"""insert into {{ environment }}_AUDIT_DB.AUDIT.AUDIT_TABLE (LOG_TIMESTAMP, PARTNERSK, FLOW_TYPE, RUN_TIME, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, PROC_NAME, INSERTED_REC_CNT, UPDATED_REC_CNT, STATUS, MESSAGE)
                    VALUES (CURRENT_TIMESTAMP, {partnersk}, ''I'',0,''{database_name}'',''{schema_name}'',''{table}'',''MERGESTAGETOBASEPY'',0,0,''FAILURE'',''No matching files found in the stage'')""").collect()
        return "No matching files found in the stage"
    # Fetch table schema dynamically
    schema_query = f"""
        SELECT COLUMN_NAME, DATA_TYPE
        FROM {database_name}.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = ''{table}''
        AND COLUMN_NAME NOT IN (''SNOWFLAKE_CREATED_AT'', ''SNOWFLAKE_UPDATED_AT'', ''SNOWFLAKE_DELETED_FLAG'',''BASECREATEDDATE'',''BASEUPDATEDDATE'',''BASEDELETEDFLAG'')
        AND TABLE_SCHEMA=''{schema_name}'' AND TABLE_CATALOG=''{database_name}''
        ORDER BY ORDINAL_POSITION;
    """
    ## mapping functin code will come here
    def get_column_mapping(file_format_path):
        ''''''
        mapping file will be present on the stage with tab delimeter
        write a logic to extract the mapping details and store it in a list
        ''''''
        ##
        
        ## immunization
        ### returns [IMMUNE_ID, IMM_CSN, IMMUNZATN_ID, IMMUNIZATION_NAME, PAT_ID, IMMUNE_DATE, IMMUNIZATION_TIME, GIVEN_BY_USER_ID, LOT, DOSE, IMMNZTN_DOSE_UNIT_C, MFG_C, IMMNZTN_STATUS_C, NDC_CODE, IMM_CVX_CODE, MED_ADMIN_COMMENT, IMM_HISTORIC_ADM_YN, EXPIRATION_DATE, SITE_C]

        ## surgicalhistory
        ### returns [SOURCE, PAT_ID, PAT_ENC_CSN_ID, LINE,  PROC_ID, PROC_NAME, HX_DATE, COMMENTS, LATERALITY_C, HX_SRC_C, CONTACT_DATE]
        pass


    schema_result = session.sql(schema_query).collect() ## [AutoPayID, customer .......]
    

    table_schema = [row["COLUMN_NAME"] for row in schema_result]

    file_list = [''@{{ environment }}_INGESTION_DB.MASTER.''+ file for file in valid_files]
    print(file_list)
    
    for file in file_list:
        create_temp_table_sql = f"""
                    CREATE OR REPLACE TEMPORARY TABLE {database_name}.{schema_name}.{table}_Temp AS
                    SELECT * exclude(basecreateddate,baseupdateddate,basedeletedflag,snowflake_created_at,snowflake_updated_at,snowflake_deleted_flag) FROM {database_name}.{schema_name}.{table} WHERE 1=0;
                """
        
        session.sql(create_temp_table_sql).collect()
    
        copy_sql = f"""
            COPY INTO {database_name}.{schema_name}.{table}_Temp ({",".join(str(i) for i in table_schema)})
            FROM ''{file}''
            FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = ''"'' FIELD_DELIMITER = ''{delimeter}'' NULL_IF = (''NULL'',''null'') SKIP_HEADER = {header} )
            ON_ERROR = CONTINUE;
        """
        session.sql(copy_sql).collect()
            
        df_stage = session.table(f''{database_name}.{schema_name}.{table}_Temp'')
        
        #df_final = df_cleaned.select([col("split_columns")[i].alias(f"col_{i+1}") for i in range(expected_col_count)])
        
        df_stage = drop_duplicates_ordered(df_stage, primary_keys, order_by_col)
        
        msg = merge_into_final(session, table, df_stage, primary_keys,file.replace("@{{ environment }}_INGESTION_DB.MASTER.",""),partnersk)
    
    return msg

';