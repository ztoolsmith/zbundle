import React from 'react';
import { render } from 'react-dom';
import { debounce } from 'lodash/debounce';
import { readFile } from 'node:fs/promises';
import { Button } from '@scope/ui';
import { local } from './local.js';

export { React, render, debounce, readFile, Button, local };
