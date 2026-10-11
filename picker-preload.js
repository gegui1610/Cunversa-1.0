const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('pickerAPI', {
  onSources: cb => ipcRenderer.on('picker:sources', (_e, list) => cb(list)),
  choose: id => ipcRenderer.send('picker:choose', id)
});
