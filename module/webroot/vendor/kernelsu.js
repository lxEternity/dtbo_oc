// KernelSU WebUI SDK 3.0.2 (Apache-2.0): retained exec API only.
let callbackCounter = 0;
function getUniqueCallbackName(prefix) {
  return `${prefix}_callback_${Date.now()}_${callbackCounter++}`;
}

export function exec(command, options) {
  if (typeof options === "undefined") {
    options = {};
  }

  return new Promise((resolve, reject) => {
    // Generate a unique callback function name
    const callbackFuncName = getUniqueCallbackName("exec");

    // Define the success callback function
    window[callbackFuncName] = (errno, stdout, stderr) => {
      resolve({ errno, stdout, stderr });
      cleanup(callbackFuncName);
    };

    function cleanup(successName) {
      delete window[successName];
    }

    try {
      ksu.exec(command, JSON.stringify(options), callbackFuncName);
    } catch (error) {
      reject(error);
      cleanup(callbackFuncName);
    }
  });
}
