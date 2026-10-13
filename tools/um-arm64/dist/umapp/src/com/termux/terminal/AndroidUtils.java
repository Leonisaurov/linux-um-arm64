package com.termux.terminal;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.Properties;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class AndroidUtils {

    public static Properties getSystemProperties(String logTag) {
        Properties systemProperties = new Properties();
        Pattern propertiesPattern = Pattern.compile("^\\[([^]]+)]: \\[(.+)]$");

        try {
            Process process = new ProcessBuilder()
                .command("/system/bin/getprop")
                .redirectErrorStream(true)
                .start();

            InputStream inputStream = process.getInputStream();
            BufferedReader bufferedReader = new BufferedReader(new InputStreamReader(inputStream));
            String line;

            while ((line = bufferedReader.readLine()) != null) {
                Matcher matcher = propertiesPattern.matcher(line);
                if (matcher.matches()) {
                    String key = matcher.group(1);
                    String value = matcher.group(2);
                    if (key != null && value != null && !key.isEmpty() && !value.isEmpty()) {
                        systemProperties.put(key, value);
                    }
                }
            }

            bufferedReader.close();
            process.destroy();
        } catch (IOException e) {
            Logger.logStackTraceWithMessage(null, logTag,
                "Failed to run \"/system/bin/getprop\" to get system properties.", e);
        }

        return systemProperties;
    }
}
