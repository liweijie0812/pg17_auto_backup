#!/bin/bash

# 配置部分
BACKUP_DIR="/workspace/pg_backup" # 修改为实际的备份路径
FULL_BACKUP_DIR="$BACKUP_DIR/full" # 全量备份路径
INCREMENTAL_BACKUP_DIR="$BACKUP_DIR/incremental" # 增量备份路径
KEEP_FULL_BACKUP_NUM=2 # 保留最近2份的全量备份
COMBINEBACKUP_OF_WEEK=7 # 合并增量备份的星期几，1-7, 1表示周一，7表示周日
CURRENT_DATE=$(date +%Y-%m-%d) # 当前日期
DAY_OF_WEEK=$(date +%u) # 1-7, 1表示周一，7表示周日
PG_BIN_PATH="/usr/lib/postgresql/17/bin/"

BACKUP_MANIFEST_FILE=""
# END 配置部分

echo "当前日期:$CURRENT_DATE"
echo "今天周 $DAY_OF_WEEK"
echo "配置周，进行备份合并"

# 切换到 postgres 用户执行脚本
run_script_as_postgres() {
    local script=$1
    if [ "$(whoami)" != "postgres" ]; then
        sudo su postgres -c "$script"
    else
        eval "$script"
    fi
}

# 检查 summarize_wal 是否开启
SUMMARIZE_WAL_STATUS=$(run_script_as_postgres "psql -t -c 'SHOW summarize_wal;'")
SUMMARIZE_WAL_STATUS=$(echo "$SUMMARIZE_WAL_STATUS" | xargs) # 去除前后空格
echo "summarize_wal: $SUMMARIZE_WAL_STATUS"
if [ "$SUMMARIZE_WAL_STATUS" != "on" ]; then
    echo "summarize_wal 未开启，请手动开启 summarize_wal"
    echo "ALTER system SET summarize_wal = ON;"
    echo "SELECT pg_reload_conf();"
    exit 1
fi

# 创建备份目录
create_backup_dir() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        run_script_as_postgres "mkdir -p $dir"
        echo "创建备份目录 $dir"
    fi
}

create_backup_dir "$BACKUP_DIR"
create_backup_dir "$FULL_BACKUP_DIR"
create_backup_dir "$INCREMENTAL_BACKUP_DIR"

# 判断 FULL_BACKUP_DIR 是否为空目录
if [ -z "$(ls -A "$FULL_BACKUP_DIR")" ]; then
    echo "$FULL_BACKUP_DIR 是空目录，进行首次全备..."
    run_script_as_postgres "${PG_BIN_PATH}pg_basebackup -D $FULL_BACKUP_DIR/$CURRENT_DATE -Xs -P"
    echo "全备完成，首次运行只做全备，退出"
    exit 0
fi

get_backup_manifest() {
    local prefix_dir=$INCREMENTAL_BACKUP_DIR
    local latest_backup_manifest_dir=$(run_script_as_postgres "ls -t $INCREMENTAL_BACKUP_DIR | head -1")
    
    if [ -z "$latest_backup_manifest_dir" ]; then
        prefix_dir=$FULL_BACKUP_DIR
        latest_backup_manifest_dir=$(run_script_as_postgres "ls -t $FULL_BACKUP_DIR | head -1")
    fi

    if [ -z "$latest_backup_manifest_dir" ]; then
        echo "未找到任何备份目录"
        exit 1
    fi

    local backup_manifest_path="$prefix_dir/$latest_backup_manifest_dir/backup_manifest"
    if ! run_script_as_postgres "test -f '$backup_manifest_path'"; then
        echo "未找到备份清单文件 $backup_manifest_path"
        exit 1
    fi
    BACKUP_MANIFEST_FILE=$backup_manifest_path
}

echo "增量备份，开始..."
CURRENT_INCREMENTAL_BACKUP_DIR=$INCREMENTAL_BACKUP_DIR/$CURRENT_DATE
if [ -d "$CURRENT_INCREMENTAL_BACKUP_DIR" ]; then
    echo "增量备份目录 $CURRENT_INCREMENTAL_BACKUP_DIR 已存在，今天已增量备份过，退出"
    exit 0
fi

get_backup_manifest

echo "BACKUP_MANIFEST_FILE: $BACKUP_MANIFEST_FILE"
if [ -z "$BACKUP_MANIFEST_FILE" ]; then
    echo "未找到备份清单文件"
    exit 1
fi
echo "${PG_BIN_PATH}pg_basebackup -D $INCREMENTAL_BACKUP_DIR/$CURRENT_DATE -Xs -P --incremental $BACKUP_MANIFEST_FILE"
run_script_as_postgres "${PG_BIN_PATH}pg_basebackup -D $INCREMENTAL_BACKUP_DIR/$CURRENT_DATE -Xs -P --incremental $BACKUP_MANIFEST_FILE"

if [ "$DAY_OF_WEEK" = "$COMBINEBACKUP_OF_WEEK" ]; then
    echo "今天是周 $DAY_OF_WEEK ，进行增量备份合并"
    _latest_full_backup_date=$(run_script_as_postgres "ls -t $FULL_BACKUP_DIR | head -1")
    _latest_full_backup_dir="$FULL_BACKUP_DIR/$_latest_full_backup_date/"
    _incremental_backup_dirs=$(run_script_as_postgres "ls -d $INCREMENTAL_BACKUP_DIR/*/ | tr '\n' ' '")
    _combinebackup_output="$FULL_BACKUP_DIR/$CURRENT_DATE"
    echo "_latest_full_backup_date: $_latest_full_backup_date"
    echo "_latest_full_backup_dir: $_latest_full_backup_dir"
    echo "_incremental_backup_dirs: $_incremental_backup_dirs"
    echo "_combinebackup_output: $_combinebackup_output"
    if [ -d "$_combinebackup_output" ]; then
        echo "今天已存在全备,不运行备份合并，退出"
        exit 0
    fi
    _combinebackup_cmd="${PG_BIN_PATH}pg_combinebackup -o $_combinebackup_output $_latest_full_backup_dir $_incremental_backup_dirs"
    echo "$_combinebackup_cmd"
    run_script_as_postgres "$_combinebackup_cmd"
    echo "增量备份合并完成"
    echo "清空增量备份目录"
    run_script_as_postgres "rm -rf $INCREMENTAL_BACKUP_DIR/*"
fi

# 获取 FULL_BACKUP_DIR 中的备份文件列表，按时间排序
FULL_BACKUP_DIRS=$(run_script_as_postgres "ls -dt $FULL_BACKUP_DIR/*/")
echo "FULL_BACKUP_DIRS 中的备份文件列表: $FULL_BACKUP_DIRS"

# 获取需要删除的备份文件列表
FULL_BACKUP_DIRS_TO_DELETE=$(echo "$FULL_BACKUP_DIRS" | tail -n +$((KEEP_FULL_BACKUP_NUM + 1)))
echo "需要删除的备份文件夹列表: $FULL_BACKUP_DIRS_TO_DELETE"

# 删除不需要的备份文件
if [ -n "$FULL_BACKUP_DIRS_TO_DELETE" ]; then
    echo "删除以下不需要的备份文件:"
    echo "$FULL_BACKUP_DIRS_TO_DELETE"
    for dir in $FULL_BACKUP_DIRS_TO_DELETE; do
        run_script_as_postgres "rm -rf $dir"
    done
else
    echo "没有需要删除的备份文件"
fi
