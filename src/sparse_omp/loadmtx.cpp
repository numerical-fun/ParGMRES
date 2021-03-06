#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cassert>

#include "utils.h"

using namespace std;

Vector loadMTXToVector(const string& filename){

    ifstream infile(filename);
    Vector vec;

    if(infile.is_open()){
        string line;
        bool check = false;

        while(getline(infile, line)){
            if(line.at(0) == '%')
                continue;

            istringstream iss(line);
            if(!check){
                int rowNum, colNum, total;
                iss >> rowNum >> colNum >> total;

                assert(colNum == 1);

                vec.resize(rowNum);
                check = true;
            }
            else{
                int r, c;
                double entry;
                iss >> r >> c >> entry;

                assert(c == 1);

                vec.set(r-1, entry);
            }
        }
    }
    else {
        cerr << "Failed to open file: " << filename << endl;
    }
    return vec;
}

Matrix loadMTXToMatrix(const string& filename){

    ifstream infile(filename);
    Matrix mat;

    if(infile.is_open()){
        string line;
        bool matSize = false;

        while(getline(infile, line)){

            if(line.at(0) == '%')
                continue;

            istringstream iss(line);
            if(!matSize){
                int rowNum, colNum, total;
                iss >> rowNum >> colNum >> total;
                mat.resize(rowNum, colNum);
                matSize = true;
            }
            else{
                int r, c;
                double entry;
                iss >> r >> c;
                bool eof = iss.eof();

                if(eof){
                    entry = 1;
                }
                else{
                    iss >> entry;
                }
                mat.set(r-1, c-1, entry);
            }
        }
    }
    else {
        cerr << "Failed to open file: " << filename << endl;
    }
    return mat;
}

void writeVecToMTXFile(const std::string& filename, const Vector& vec){

    ofstream outfile(filename);

    int rowNum = vec.size();
    int colNum = 1;

    if(outfile.is_open()){
        outfile << "%%MatrixMarket matrix coordinate real general\n";
        outfile << "%-------------------------------------------------------------------------------\n";
        outfile << "%-------------------------------------------------------------------------------\n";
        outfile << rowNum << " " << colNum << " " << rowNum*colNum << endl;

        for(int i = 1; i <= rowNum; i++){
            double val = vec.get(i-1);
            if(val != 0){
                outfile << i << " 1 " << val << endl;
            }
        }
    }
    else{
        cerr << "Failed to open file: " << filename << endl;
    }
}

void writeMatToMTXFile(const std::string& filename, const Matrix& mat){

    ofstream outfile(filename);

    int rowNum = mat.nRows();
    int colNum = mat.nCols();
    int count = 0;

    if(outfile.is_open()){
        outfile << "%%MatrixMarket matrix coordinate real general\n";
        outfile << "%-------------------------------------------------------------------------------\n";
        outfile << "%-------------------------------------------------------------------------------\n";


        for(int i = 1; i <= rowNum; i++){
            for(int j = 1; j <= colNum; j++){
                double val = mat.get(i-1, j-1);
                if(val != 0){
                    count++;
                }
            }
        }
        outfile << rowNum << " " << colNum << " " << count << endl;

        for(int i = 1; i <= rowNum; i++){
            for(int j = 1; j <= colNum; j++){
                double val = mat.get(i-1, j-1);
                if(val != 0){
                    outfile << i << " " << j << " " << val << endl;
                }
            }
        }
    }
    else{
        cerr << "Failed to open file: " << filename << endl;
    }
}
