#!/bin/sh

# Load configuration from an external file
CONFIG_FILE="./backup_config.conf"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "Configuration file not found!"
    exit 1
fi

# Check required commands
for cmd in rsync sshpass rclone mail wp; do
    command -v $cmd >/dev/null 2>&1 || { echo >&2 "$cmd is required but it's not installed. Aborting."; exit 1; }
done

# Function to get the current date in MM-DD-YYYY format
get_date() {
    date "+%m-%d-%Y"
}

# Function to send email notification
send_email() {
    local subject="$1"
    local message="$2"
    echo "$message" | mail -s "$subject" "$EMAIL_RECIPIENT"
}

# Function to increment the directory name if it already exists
increment_dir_name() {
    local base_dir="$1"
    local i=1
    while rclone lsf "$GDRIVE_REMOTE_DIR/${base_dir}_$i" >/dev/null 2>&1; do
        i=$((i + 1))
    done
    echo "${base_dir}_$i"
}

# Function to perform backup (local and Google Drive)
perform_backup() {
    local source_dir="$SFTP_USER@$SFTP_SERVER:$SFTP_REMOTE_DIR"
    local backup_base_dir="$LOCAL_BACKUP_DIR/$(get_date)"
    local backup_dir="$backup_base_dir"

    if [ -d "$backup_dir" ]; then
        read -p "Backup directory already exists: $backup_dir. Would you like to use a new directory with an incrementing number? (y/n): " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            backup_dir=$(increment_dir_name "$backup_base_dir")
        else
            echo "Backup cancelled."
            send_email "Backup Cancelled" "Backup was cancelled by the user for $source_dir."
            return 1
        fi
    fi

    mkdir -p "$backup_dir"

    # Perform the local backup using rsync with SSH
    rsync -avucP -e "sshpass -p $SFTP_PASSWORD ssh -p $SFTP_PORT" --log-file=rsync_error.log "$source_dir" "$backup_dir"
    if [ $? -eq 0 ]; then
        echo "Local backup complete!"
        # Perform the Google Drive backup using rclone
        local gdrive_backup_dir="$GDRIVE_REMOTE_DIR/$(get_date)"
        if rclone lsf "$gdrive_backup_dir" >/dev/null 2>&1; then
            gdrive_backup_dir=$(increment_dir_name "$(get_date)")
        fi
        rclone copy "$backup_dir" "$gdrive_backup_dir" -P --log-file=rclone_log.log --log-level DEBUG
        if [ $? -eq 0 ]; then
            echo "Google Drive backup complete!"
            send_email "Backup Successful" "Local and Google Drive backup completed successfully for $source_dir."
        else
            echo "Google Drive backup failed!"
            send_email "Backup Failed" "Google Drive backup failed for $source_dir. Check rclone_log.log for details."
        fi
    else
        echo "Local backup failed! Check rsync_error.log for details."
        send_email "Backup Failed" "Local backup failed for $source_dir. Check rsync_error.log for details."
    fi
}

# Function to perform SFTP and Google Drive backup
sftp_backup() {
    local backup_base_dir="$LOCAL_BACKUP_DIR/$(get_date)"
    local backup_dir="$backup_base_dir"

    if [ -d "$backup_dir" ]; then
        read -p "Backup directory already exists: $backup_dir. Would you like to use a new directory with an incrementing number? (y/n): " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            backup_dir=$(increment_dir_name "$backup_base_dir")
        else
            echo "Backup cancelled."
            send_email "Backup Cancelled" "Backup was cancelled by the user for SFTP backup."
            return 1
        fi
    fi

    mkdir -p "$backup_dir"

    # Perform the SFTP backup using rsync
    rsync -avucP -e "sshpass -p $SFTP_PASSWORD ssh -p $SFTP_PORT" --log-file=rsync_error.log "$SFTP_USER@$SFTP_SERVER:$SFTP_REMOTE_DIR" "$backup_dir"
    if [ $? -eq 0 ]; then
        echo "SFTP backup complete!"
        # Perform the Google Drive backup using rclone
        local gdrive_backup_dir="$GDRIVE_REMOTE_DIR/$(get_date)"
        if rclone lsf "$gdrive_backup_dir" >/dev/null 2>&1; then
            gdrive_backup_dir=$(increment_dir_name "$(get_date)")
        fi
        rclone copy "$backup_dir" "$gdrive_backup_dir" -P --log-file=rclone_log.log --log-level DEBUG
        if [ $? -eq 0 ]; then
            echo "Google Drive clone complete!"
            send_email "Backup Successful" "SFTP and Google Drive backup completed successfully."
        else
            echo "Google Drive clone failed!"
            send_email "Backup Failed" "Google Drive backup failed after SFTP backup. Check rclone_log.log for details."
        fi
    else
        echo "SFTP backup failed! Check rsync_error.log for details."
        send_email "Backup Failed" "SFTP backup failed. Check rsync_error.log for details."
    fi
}

# Function to update WordPress plugins locally
update_wp_plugins_local() {
    local wp_log_file="wp_update_log_local.log"
    wp plugin update --all --path="$WP_LOCAL_PATH" > "$wp_log_file" 2>&1
    if [ $? -eq 0 ]; then
        echo "WordPress plugins updated successfully!"
        send_email "WordPress Plugins Updated" "All WordPress plugins were updated successfully."
    else
        echo "Failed to update WordPress plugins!"
        send_email "WordPress Plugins Update Failed" "There was an error updating WordPress plugins. Please check $wp_log_file for details."
    fi

    # Check for errors in the WP-CLI log file
    if grep -q "Error" "$wp_log_file"; then
        send_email "WordPress Plugin Update Errors" "Errors were found during the WordPress plugin update. Please check $wp_log_file for details."
    fi
}

# Function to update WordPress plugins remotely via SFTP
update_wp_plugins_remote() {
    # Prompt the user for their current directory
    read -p "Are you in the 'local' or 'backups' directory? (local/backups): " current_directory
    if [ "$current_directory" = "backups" ]; then
        echo "Operation not allowed in the 'backups' directory. Exiting."
        return 0
    fi

    local wp_log_file="wp_update_log_remote.log"
    local wp_versions_file="wp_plugin_versions.txt"
    
    # Create maintenance documentation directory
    local maintenance_dir="maintenance_documentation_$(date +%m-%d-%Y)"
    mkdir -p "$maintenance_dir"
    
    # Retrieve current plugin versions before the update
    sshpass -p "$SFTP_PASSWORD" ssh -p "$SFTP_PORT" "$SFTP_USER@$SFTP_SERVER" <<EOF
cd $WP_REMOTE_PATH
if [ -f wp-cli.phar ]; then
    WP_CLI='./wp-cli.phar'
else
    WP_CLI='wp'
fi
\$WP_CLI plugin list --format=csv > $wp_versions_file
EOF

    # Check if the command succeeded
    if [ $? -ne 0 ]; then
        echo "Failed to retrieve current plugin versions from the remote server!"
        send_email "WordPress Plugin Retrieval Failed" "There was an error retrieving current plugin versions on the remote server."
        return 1
    fi

    # Download the plugin versions file
    sshpass -p "$SFTP_PASSWORD" scp -P "$SFTP_PORT" "$SFTP_USER@$SFTP_SERVER:$WP_REMOTE_PATH/$wp_versions_file" "$maintenance_dir/"

    # Perform the plugin update
    sshpass -p "$SFTP_PASSWORD" ssh -p "$SFTP_PORT" "$SFTP_USER@$SFTP_SERVER" <<EOF
cd $WP_REMOTE_PATH
if [ -f wp-cli.phar ]; then
    WP_CLI='./wp-cli.phar'
else
    WP_CLI='wp'
fi
\$WP_CLI plugin update --all --path='$WP_REMOTE_PATH' > wp_update_log.log 2>&1
EOF

    if [ $? -eq 0 ]; then
        echo "WordPress plugins updated successfully on remote server!"
        send_email "WordPress Plugins Updated" "All WordPress plugins were updated successfully on the remote server."
    else
        echo "Failed to update WordPress plugins on remote server!"
        send_email "WordPress Plugins Update Failed" "There was an error updating WordPress plugins on the remote server. Please check the remote wp_update_log.log for details."
    fi

    # Retrieve the updated plugin versions
    sshpass -p "$SFTP_PASSWORD" ssh -p "$SFTP_PORT" "$SFTP_USER@$SFTP_SERVER" <<EOF
cd $WP_REMOTE_PATH
if [ -f wp-cli.phar ]; then
    WP_CLI='./wp-cli.phar'
else
    WP_CLI='wp'
fi
\$WP_CLI plugin list --format=csv > $wp_versions_file
EOF

    # Check if the command succeeded
    if [ $? -ne 0 ]; then
        echo "Failed to retrieve updated plugin versions from the remote server!"
        send_email "WordPress Plugin Retrieval Failed" "There was an error retrieving updated plugin versions on the remote server."
        return 1
    fi

    # Download the updated plugin versions file
    sshpass -p "$SFTP_PASSWORD" scp -P "$SFTP_PORT" "$SFTP_USER@$SFTP_SERVER:$WP_REMOTE_PATH/$wp_versions_file" "$maintenance_dir/wp_versions_updated.csv"

    # Compare and create the versions update file
    local update_report_file="${maintenance_dir}/wp_plugin_update_report.txt"
    echo "Plugin Name,Version Before,Version After" > "$update_report_file"
    awk 'FNR==NR {a[$1]=$2; next} {print $1","a[$1]","$2}' FS=, OFS=, "${maintenance_dir}/wp_plugin_versions.txt" "${maintenance_dir}/wp_versions_updated.csv" >> "$update_report_file"

    # Check for errors in the WP-CLI log file
    sshpass -p "$SFTP_PASSWORD" scp -P "$SFTP_PORT" "$SFTP_USER@$SFTP_SERVER:$WP_REMOTE_PATH/wp_update_log.log" "$maintenance_dir/$wp_log_file"
    if grep -q "Error" "$maintenance_dir/$wp_log_file"; then
        send_email "WordPress Plugin Update Errors" "Errors were found during the remote WordPress plugin update. Please check $maintenance_dir/$wp_log_file for details."
    fi
}

# Function to update WordPress plugins with choice of local or remote
update_wp_plugins() {
    read -p "Update plugins locally or remotely? (local/remote): " update_location
    case $update_location in
        local)
            update_wp_plugins_local
            ;;
        remote)
            update_wp_plugins_remote
            ;;
        *)
            echo "Invalid option. Please choose 'local' or 'remote'."
            ;;
    esac
}

# Function to schedule a cron job
schedule_backup() {
    local dir1="$SFTP_REMOTE_DIR"
    crontab -l | grep -q '#a' && echo "crontab exists" || (crontab -l; echo "#a") | sort -u | crontab -
    echo "How often would you like to backup?"
    select time in day week month; do
        case $time in
            day)
                read -p "What time of day (hour only) would you like to backup on? (24 hour format, 0 - 23): " hour
                if ! [[ "$hour" =~ ^[0-9]+$ ]] || ! [ "$hour" -ge 0 -a "$hour" -le 23 ]; then
                    echo "Error: Hour must be an integer between 0 and 23"
                    exit 1
                fi
                (crontab -l; echo "0 $hour * * * rsync -avucP -e \"sshpass -p $SFTP_PASSWORD ssh -p $SFTP_PORT\" $SFTP_USER@$SFTP_SERVER:$dir1 $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) --log-file=rsync_error.log && rclone copy $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) $GDRIVE_REMOTE_DIR/\$(date +\%m-\%d-\%Y) -P --log-file=rclone_log.log --log-level DEBUG") | sort -u | crontab -
                break
                ;;
            week)
                read -p "What day of the week would you like to backup? (0 - 6): " dow
                read -p "What time of day (hour only) would you like to backup on? (24 hour format, 0 - 23): " hour
                if ! [[ "$hour" =~ ^[0-9]+$ ]] || ! [ "$hour" -ge 0 -a "$hour" -le 23 ] || ! [[ "$dow" =~ ^[0-9]+$ ]] || ! [ "$dow" -ge 0 -a "$dow" -le 6 ]; then
                    echo "Error: Hour must be an integer between 0 and 23 and day of week must be an integer between 0 and 6"
                    exit 1
                fi
                (crontab -l; echo "0 $hour * * $dow rsync -avucP -e \"sshpass -p $SFTP_PASSWORD ssh -p $SFTP_PORT\" $SFTP_USER@$SFTP_SERVER:$dir1 $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) --log-file=rsync_error.log && rclone copy $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) $GDRIVE_REMOTE_DIR/\$(date +\%m-\%d-\%Y) -P --log-file=rclone_log.log --log-level DEBUG") | sort -u | crontab -
                break
                ;;
            month)
                read -p "What day of the month would you like to backup on? (1 - 31): " dom
                read -p "What time of day (hour only) would you like to backup on? (24 hour format, 0 - 23): " hour
                if ! [[ "$dom" =~ ^[0-9]+$ ]] || ! [ "$dom" -ge 1 -a "$dom" -le 31 ] || ! [[ "$hour" =~ ^[0-9]+$ ]] || ! [ "$hour" -ge 0 -a "$hour" -le 23 ]; then
                    echo "Error: Day of month must be an integer between 1 and 31 and hour must be an integer between 0 and 23"
                    exit 1
                fi
                (crontab -l; echo "0 $hour $dom * * rsync -avucP -e \"sshpass -p $SFTP_PASSWORD ssh -p $SFTP_PORT\" $SFTP_USER@$SFTP_SERVER:$dir1 $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) --log-file=rsync_error.log && rclone copy $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) $GDRIVE_REMOTE_DIR/\$(date +\%m-\%d-\%Y) -P --log-file=rclone_log.log --log-level DEBUG") | sort -u | crontab -
                break
                ;;
            *)
                echo "Invalid option $REPLY"
                ;;
        esac
    done
    echo "Schedule is set! If you would like to remove an entry type 'crontab -e' in your terminal and remove it."
}

# Function to schedule a daily cron job for SFTP and GDrive backup
daily_cron_backup() {
    read -p "What time of day (hour only) would you like to backup on? (24 hour format, 0 - 23): " hour
    if ! [[ "$hour" =~ ^[0-9]+$ ]] || ! [ "$hour" -ge 0 -a "$hour" -le 23 ]; then
        echo "Error: Hour must be an integer between 0 and 23"
        exit 1
    fi
    cron_command="0 $hour * * * rsync -avucP -e \"sshpass -p $SFTP_PASSWORD ssh -p $SFTP_PORT\" $SFTP_USER@$SFTP_SERVER:$SFTP_REMOTE_DIR $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) --log-file=rsync_error.log && rclone copy $LOCAL_BACKUP_DIR/\$(date +\%m-\%d-\%Y) $GDRIVE_REMOTE_DIR/\$(date +\%m-\%d-\%Y) -P --log-file=rclone_log.log --log-level DEBUG"
    (crontab -l; echo "$cron_command #a") | sort -u | crontab -
    echo "Daily cron job is set!"
}

# Menu options
select opt in local sftp update_wp_plugins schedule daily_cron clear info quit; do
    case $opt in
        local)
            perform_backup "$SFTP_REMOTE_DIR"
            ;;
        sftp)
            sftp_backup
            ;;
        update_wp_plugins)
            update_wp_plugins
            ;;
        schedule)
            schedule_backup
            ;;
        daily_cron)
            daily_cron_backup
            ;;
        info)
            echo 
            echo "A backup tool for web maintenance."
            echo "Web developer: Jawon"
            echo  
            ;;
        clear)
            read -p "Are you sure you want to continue? (y/n): " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                crontab -r
                echo "Crontab cleared."
            fi
            ;;
        quit)
            break
            ;;
        *)
            echo "Invalid option $REPLY"
            ;;
    esac
done
