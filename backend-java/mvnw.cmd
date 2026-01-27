@ECHO OFF
SETLOCAL

SET WRAPPER_DIR=%~dp0.mvn\wrapper
SET PROPS=%WRAPPER_DIR%\maven-wrapper.properties
SET JAR=%WRAPPER_DIR%\maven-wrapper.jar

IF NOT EXIST "%PROPS%" (
  ECHO Missing %PROPS%
  EXIT /B 1
)

FOR /F "usebackq tokens=1* delims==" %%A IN ("%PROPS%") DO (
  IF "%%A"=="wrapperUrl" SET WRAPPER_URL=%%B
)

IF NOT EXIST "%JAR%" (
  ECHO Downloading Maven Wrapper jar...
  POWERSHELL -NoProfile -ExecutionPolicy Bypass -Command "(New-Object System.Net.WebClient).DownloadFile('%WRAPPER_URL%','%JAR%')" || EXIT /B 1
)

SET JAVA_CMD=java
IF NOT "%JAVA_HOME%"=="" SET JAVA_CMD=%JAVA_HOME%\bin\java

%JAVA_CMD% -classpath "%JAR%" -Dmaven.multiModuleProjectDirectory=%~dp0 org.apache.maven.wrapper.MavenWrapperMain %*
ENDLOCAL
